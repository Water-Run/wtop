local Engine = require("wtop.engine")
local ProcessTable = require("wtop.model.process_table")

local M = {}
local EMPTY_PROCESS_SOURCE = {}
local PROCESS_VIEW_CACHE = setmetatable({}, { __mode = "k" })
local TABLE_ROW_LIMIT = 512

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

local function process_sort_label(i18n, key)
    local labels = {
        cpu = { "process.sort.cpu", "CPU" },
        memory = { "process.sort.memory", "Memory" },
        pid = { "process.sort.pid", "PID" },
        name = { "process.sort.name", "Name" },
        io_read = { "process.sort.io_read", "I/O read" },
        io_write = { "process.sort.io_write", "I/O write" },
    }
    local label = labels[key] or labels.cpu
    return translated(i18n, label[1], label[2])
end

local function process_status_text(i18n, status)
    local filter = status.query ~= "" and translated(i18n, "process.filter_status",
        " · Filter: {query}", { query = status.query }) or ""
    local tree = status.tree and translated(i18n, "process.tree_status", " · Tree") or ""
    local collection = status.collection_truncated and translated(i18n, "process.collection_truncated",
        " · collection capped at {limit}", { limit = status.collection_limit or status.total }) or ""
    tree = tree .. collection
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

local function top_processes(snapshot, format, controller, i18n)
    local source = snapshot.processes and snapshot.processes.list or EMPTY_PROCESS_SOURCE
    controller:update_if_changed(source)
    local status = controller:status()
    status.collection_truncated = snapshot.processes and snapshot.processes.truncated == true or false
    status.collection_limit = snapshot.processes and snapshot.processes.process_limit
    local locale_id = type(i18n.locale) == "function" and i18n:locale() or nil
    local cached = PROCESS_VIEW_CACHE[controller]
    if cached and cached.revision == status.revision and cached.format == format
        and cached.i18n == i18n and cached.locale_id == locale_id
        and cached.collection_truncated == status.collection_truncated
        and cached.collection_limit == status.collection_limit
    then
        return cached.rows, status, cached.status_text
    end
    local rows = {}
    local clock_ticks = snapshot.processes and snapshot.processes.clock_ticks_per_second or 100
    local total_memory = snapshot.memory and snapshot.memory.total_bytes
    for _, process in ipairs(controller:rows()) do
        -- The kernel truncates /proc/<pid>/stat's comm at 15 characters, so a
        -- table built from it shows "systemd-timesyn".  cmdline is the honest
        -- name; `show_paths` decides whether its directory is kept.
        local name = process.command
        if name and not status.show_paths then
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
            name = prefix .. (process.tree_has_children and "▾ " or "· ") .. name
        end
        local cpu_seconds = type(process.cpu_ticks) == "number"
            and clock_ticks > 0 and process.cpu_ticks / clock_ticks or nil
        rows[#rows + 1] = {
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
            state = process.state or "?",
            user = process.user or "—",
            -- /proc/<pid>/io counters are cumulative since exec.  Presenting
            -- them as a per-second rate would be a fabrication: the collector
            -- samples them on demand for the selected process only.
            read = bytes(format, process.io and process.io.read_bytes),
            write = bytes(format, process.io and process.io.write_bytes),
            process = process,
        }
    end
    local status_text = process_status_text(i18n, status)
    PROCESS_VIEW_CACHE[controller] = {
        revision = status.revision,
        format = format,
        i18n = i18n,
        locale_id = locale_id,
        collection_truncated = status.collection_truncated,
        collection_limit = status.collection_limit,
        rows = rows,
        status_text = status_text,
    }
    return rows, status, status_text
end

local function core_rows(snapshot, format)
    local rows = {}
    for _, core in ipairs(snapshot.cpu and snapshot.cpu.cores or {}) do
        rows[#rows + 1] = {
            core = core.name,
            total = percent(format, core.utilization),
            total_value = core.utilization,
            user = percent(format, core.user),
            system = percent(format, core.system),
            iowait = percent(format, core.iowait),
            irq = percent(format, core.irq),
            steal = percent(format, core.steal),
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
    for _, device in ipairs(snapshot.disks and snapshot.disks.devices or {}) do
        local identity = device.identity or {}
        local uninteresting = identity.virtual == true
            and (identity.size_bytes == nil or identity.size_bytes == 0
                or (device.read_bytes_per_second or 0) == 0
                and (device.write_bytes_per_second or 0) == 0)
        if uninteresting and not options.show_virtual then
            hidden = hidden + 1
        elseif #rows < TABLE_ROW_LIMIT then
            rows[#rows + 1] = {
                device = device.name,
                model = identity.model or identity.vendor or "—",
                size = bytes(format, identity.size_bytes),
                medium = identity.rotational == 1 and "HDD"
                    or (identity.rotational == 0 and "SSD" or "—"),
                scheduler = identity.scheduler or "—",
                read = rate(format, device.read_bytes_per_second),
                write = rate(format, device.write_bytes_per_second),
                busy = percent(format, device.busy_percent),
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
        rows[#rows + 1] = {
            interface = interface.name,
            state = interface.operstate or "?",
            receive = rate(format, rates.rx_bytes_per_second),
            transmit = rate(format, rates.tx_bytes_per_second),
            speed = interface.speed_mbps and (tostring(interface.speed_mbps) .. " Mbit/s") or "—",
            mac = interface.address or "—",
            mtu = interface.mtu and tostring(interface.mtu) or "—",
            duplex = interface.duplex or "—",
            errors = tostring(errors),
            drops = tostring(drops),
            error_value = errors + drops,
        }
    end
    return rows
end

local function connection_rows(snapshot)
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
    local selected = bounded_best_values(
        snapshot.connections and snapshot.connections.connections or {}, TABLE_ROW_LIMIT, better)
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
            remote_endpoint = connection.remote_endpoint and connection.remote_endpoint.text or "—",
            state = connection.state or "—",
            process = #owners > 0 and table.concat(owners, ", ") or "—",
            queue = tostring((connection.tx_queue or 0) + (connection.rx_queue or 0)),
            uid = connection.uid and tostring(connection.uid) or "—",
            connection_ref = connection,
        }
    end
    return rows
end

local function gpu_rows(snapshot, format)
    local rows = {}
    local sensors_by_class, sensors_by_target = {}, {}
    for _, sensor in ipairs(snapshot.sensors and snapshot.sensors.devices or {}) do
        if sensor.class then sensors_by_class[sensor.class] = sensor end
        if sensor.device_target then sensors_by_target[sensor.device_target] = sensor end
    end
    for _, gpu in ipairs(snapshot.gpus and snapshot.gpus.devices or {}) do
        local metrics = gpu.metrics or {}
        local matched, seen = {}, {}
        local function add_sensor(sensor)
            if sensor and not seen[sensor] then
                seen[sensor] = true
                matched[#matched + 1] = sensor
            end
        end
        for _, reference in ipairs(gpu.hwmon_refs or {}) do
            add_sensor(reference.class and sensors_by_class[reference.class])
            add_sensor(reference.device_target and sensors_by_target[reference.device_target])
        end
        add_sensor(gpu.device_target and sensors_by_target[gpu.device_target])
        local joined_temperature, joined_power
        for _, sensor in ipairs(matched) do
            for _, channel in ipairs(sensor.channels or {}) do
                if type(channel.input) == "number" then
                    if channel.type == "temperature" then
                        joined_temperature = joined_temperature
                            and math.max(joined_temperature, channel.input) or channel.input
                    elseif channel.type == "power" then
                        -- A hwmon device can expose overlapping total and rail
                        -- channels.  The maximum is useful without pretending
                        -- that summing them is a physical board-power total.
                        joined_power = joined_power and math.max(joined_power, channel.input)
                            or channel.input
                    end
                end
            end
        end
        local temperature_celsius = metrics.temperature_celsius or joined_temperature
        local power_watts = metrics.power_watts or joined_power
        local memory_used = metrics.memory_used_bytes or metrics.process_memory_bytes
        local memory_total = metrics.memory_total_bytes
        local memory_text = "—"
        if memory_used then
            memory_text = bytes(format, memory_used)
            if memory_total then memory_text = memory_text .. " / " .. bytes(format, memory_total) end
        end
        local pci = gpu.pci or {}
        local pcie = pci.current_link_speed
        if pci.current_link_width then
            pcie = (pcie and (pcie .. " ") or "") .. "x" .. tostring(pci.current_link_width)
        end
        rows[#rows + 1] = {
            gpu = gpu.model_name or gpu.card or gpu.id,
            vendor = gpu.vendor_name or gpu.vendor or "?",
            driver = gpu.driver or "?",
            utilization = percent(format, metrics.utilization_percent),
            memory = memory_text,
            frequency = frequency(format, metrics.frequency_current_hz),
            pcie = pcie or "—",
            temperature = temperature_celsius
                and formatted(function() return assert(format:temperature(temperature_celsius)) end)
                or "—",
            power = power_watts and string.format("%.1f W", power_watts) or "—",
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

local function cpufreq_rows(snapshot, format)
    local rows = {}
    for _, policy in ipairs(snapshot.cpu_frequency and snapshot.cpu_frequency.policies or {}) do
        local cpus = policy.affected_cpus or policy.related_cpus or {}
        local labels = {}
        for index, cpu in ipairs(cpus) do labels[index] = tostring(cpu) end
        local frequencies = policy.frequencies or {}
        rows[#rows + 1] = {
            policy = policy.policy or policy.id,
            cpus = table.concat(labels, ","),
            current = frequency(format, frequencies.current_hz),
            minimum = frequency(format, frequencies.scaling_minimum_hz or frequencies.hardware_minimum_hz),
            maximum = frequency(format, frequencies.scaling_maximum_hz or frequencies.hardware_maximum_hz),
            governor = policy.governor or "—",
            driver = policy.driver or "—",
            quality = frequencies.current_quality or policy.quality or "—",
        }
    end
    return rows
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
    local function better(left, right)
        if left.alarm ~= right.alarm then return left.alarm end
        if left.device == right.device then return left.sensor < right.sensor end
        return left.device < right.device
    end
    for _, device in ipairs(snapshot.sensors and snapshot.sensors.devices or {}) do
        for _, channel in ipairs(device.channels or {}) do
            bounded_best_add(rows, TABLE_ROW_LIMIT, better, {
                device = device.name or device.class or "?",
                sensor = channel.label or (channel.type .. " " .. tostring(channel.index)),
                type = channel.type,
                value = sensor_value(channel, format),
                status = channel.fault and "FAULT" or (channel.alarm and "ALARM" or channel.quality or "—"),
                alarm = channel.alarm == true or channel.fault == true,
            })
        end
    end
    table.sort(rows, better)
    return rows
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
    local selected = bounded_best_values(source, TABLE_ROW_LIMIT,
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
            readonly = mount.readonly and "ro" or "rw",
        }
    end
    return rows, hidden
end

local function workload_rows(snapshot, format)
    local rows = {}
    for _, workload in ipairs(snapshot.workloads and snapshot.workloads.workloads or {}) do
        if #rows >= TABLE_ROW_LIMIT then break end
        local io_rates = workload.io and workload.io.totals and workload.io.totals.rates or {}
        local pressure = workload.pressure and workload.pressure.cpu
        local cpu_pressure = pressure and pressure.some and pressure.some.avg10
        rows[#rows + 1] = {
            workload = string.rep("  ", math.min(workload.depth or 0, 6)) .. (workload.name or workload.id),
            cpu = percent(format, workload.cpu and workload.cpu.utilization_percent),
            memory = bytes(format, workload.memory and workload.memory.current_bytes),
            read = rate(format, io_rates.rbytes_per_second),
            write = rate(format, io_rates.wbytes_per_second),
            processes = tostring(workload.processes and workload.processes.count or 0),
            pressure = percent(format, cpu_pressure),
            quality = workload.quality or "—",
            raw_cpu = workload.cpu and workload.cpu.utilization_percent or -1,
            workload_ref = workload,
        }
    end
    return rows
end

local function power_rows(snapshot, format)
    local rows = {}
    for _, zone in ipairs(snapshot.power and snapshot.power.zones or {}) do
        if #rows >= TABLE_ROW_LIMIT then break end
        local constraint = zone.constraints and zone.constraints[1]
        local power = type(zone.power_watts) == "number"
            and formatted(function()
                return assert(format:number(zone.power_watts, { precision = 2 }))
            end) .. " W" or "—"
        local energy = type(zone.energy_joules) == "number"
            and formatted(function()
                return assert(format:number(zone.energy_joules, { precision = 1 }))
            end) .. " J" or "—"
        local limit = constraint and type(constraint.power_limit_watts) == "number"
            and formatted(function()
                return assert(format:number(constraint.power_limit_watts, { precision = 1 }))
            end) .. " W" or "—"
        rows[#rows + 1] = {
            zone = zone.name or zone.id or "?",
            domain = zone.source_kind or "—",
            power = power,
            energy = energy,
            limit = limit,
            source = zone.power_source or zone.power_quality or "—",
            state = zone.enabled == false and "disabled" or (zone.quality or "—"),
            aggregate = zone.aggregate == true,
        }
    end
    table.sort(rows, function(left, right)
        if left.aggregate ~= right.aggregate then return left.aggregate end
        if left.domain ~= right.domain then return left.domain < right.domain end
        return left.zone < right.zone
    end)
    return rows
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
        entry("compute.family", "Family",
            string.format("%s / %s / %s", tostring(identity.family or "—"),
                tostring(identity.model or "—"), tostring(identity.stepping or "—"))),
    }
    if topology.threads then
        entries[#entries + 1] = entry("compute.sockets", "Sockets",
            plural_unit(i18n, "compute.socket_count", "socket", "sockets", topology.sockets or 0))
        entries[#entries + 1] = entry("compute.cores", "Physical cores",
            plural_unit(i18n, "compute.core_count", "core", "cores", topology.physical_cores or 0))
        entries[#entries + 1] = entry("compute.threads", "Logical CPUs",
            plural_unit(i18n, "compute.thread_count", "thread", "threads", topology.threads or 0))
    end
    if identity.microcode then
        entries[#entries + 1] = entry("compute.microcode", "Microcode", identity.microcode)
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
            local detail = tostring(core_type.logical_cpu_count or 0) .. "T"
            if core_type.maximum_frequency_hz then
                detail = detail .. " · " .. frequency(format, core_type.maximum_frequency_hz)
            end
            entries[#entries + 1] = {
                label = tostring(core_type.model_name or core_type.part or "CPU"),
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
    if not firmware then
        return { entry("system.firmware_unavailable", "Firmware",
            translated(i18n, "system.dmi_unavailable", "DMI not exposed by this platform")) }
    end
    local entries = {
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
    return entries
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
        local detail = battery.capacity_percent
            and string.format("%.0f%%", battery.capacity_percent) or "—"
        items[#items + 1] = {
            label = battery.name,
            value = battery.capacity_percent,
            display_value = detail,
        }
    end
    for _, supply in ipairs(supplies.supplies or {}) do
        items[#items + 1] = {
            label = supply.name,
            value = supply.online and 100 or 0,
            display_value = supply.online
                and translated(i18n, "system.online", "online")
                or translated(i18n, "system.offline", "offline"),
            token = supply.online and "metric.good" or "text.muted",
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

local COLLECTOR_RESOURCE = {
    cpu = "cpu", cpu_info = "cpu_info", memory = "memory", pressure = "pressure",
    disk = "disks", network = "network", connections = "connections",
    process = "processes", gpu = "gpus", cpufreq = "cpu_frequency", hwmon = "sensors",
    powercap = "power", mounts = "mounts", cgroup = "workloads",
    system_info = "system", power_supply = "power_supplies",
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
        ["service.sshd"] = { "d", "inspector.sshd", "sshd service and listeners" },
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

local function workload_detail_entries(snapshot, format, i18n)
    local summary = snapshot.workloads and snapshot.workloads.summary
    if not summary then return {} end
    local root = summary.root or {}
    local entries = {
        entry("workloads.nodes", "Visible cgroups", summary.node_count or 0),
        entry("workloads.processes", "Visible processes", summary.visible_process_count or 0),
        entry("workloads.partial", "Partial cgroups", summary.partial_node_count or 0,
            { token = (summary.partial_node_count or 0) > 0 and "metric.warn" or nil }),
        section("workloads.root_section", "Root cgroup"),
        entry("metrics.cpu", "CPU", percent(format, root.cpu_utilization_percent)),
        entry("metrics.memory", "Memory", bytes(format, root.memory_current_bytes)),
    }
    if (summary.partial_node_count or 0) > 0 then
        entries[#entries + 1] = section("workloads.why_section", "Why partial")
        entries[#entries + 1] = {
            label = "",
            value = translated(i18n, "workloads.partial_reason",
                "Controllers not delegated to this cgroup, or files unreadable as this user."),
            token = "text.muted",
        }
    end
    return entries
end

local function smart_hint_entries(snapshot, capabilities, i18n)
    local inspectors = capabilities and capabilities.inspectors or {}
    local smart = inspectors["storage.smart"]
    local available = type(smart) == "table" and smart.available == true
    return {
        entry("storage.smart_key", "Inspect", translated(i18n, "storage.smart_hint_short",
            "press s to choose a device")),
        entry("inspector.status", "Status", available
            and translated(i18n, "inspector.ready", "ready")
            or translated(i18n, "inspector.helper_missing", "smartctl not available"),
            { token = available and "metric.good" or "metric.warn" }),
        { label = "", value = translated(i18n, "storage.smart_standby",
            "Read-only probes are lazy; standby disks are not awakened."),
          token = "text.muted" },
    }
end

function M.build(engine, snapshot, i18n, capabilities, active_tab, process_controller,
        visible_widgets, options)
    options = options or {}
    local format = i18n.format
    local kernel_type = snapshot.system and snapshot.system.kernel
        and snapshot.system.kernel.type
    local linux_host = (options.platform or kernel_type or "Linux") == "Linux"
    local function visible(widget_id)
        return type(visible_widgets) ~= "table" or visible_widgets[widget_id] == true
    end
    local function on(tab, widget_id)
        return (not active_tab or active_tab == tab) and visible(widget_id)
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

    local process_rows, process_status, process_status_display
    if on("processes", "process_table") then
        process_controller = process_controller or ProcessTable.new()
        process_rows, process_status, process_status_display = top_processes(
            snapshot, format, process_controller, i18n)
    else
        process_rows = {}
        process_status = process_controller and process_controller:status() or ProcessTable.new():status()
        process_status_display = process_status_text(i18n, process_status)
    end

    local cores = on("compute", "core_table") and core_rows(snapshot, format) or {}
    local core_items = {}
    if on("compute", "core_bars") or on("overview", "core_overview") then
        core_items = core_bar_items(snapshot, format)
    end
    local disks, disks_hidden = {}, 0
    if on("storage", "disk_table") then
        disks, disks_hidden = disk_rows(snapshot, format, { show_virtual = options.show_virtual_devices })
    end
    local interfaces = on("network", "network_table") and network_rows(snapshot, format) or {}
    local connections = on("network", "connection_table") and connection_rows(snapshot) or {}
    local addresses = on("network", "address_table") and address_rows(snapshot) or {}
    local gpu_table_rows = on("gpu", "gpu_table") and gpu_rows(snapshot, format) or {}
    local gpu_process_table_rows, gpu_process_total = {}, 0
    if on("gpu", "gpu_process_table") then
        gpu_process_table_rows, gpu_process_total = gpu_process_rows(snapshot, format)
    end
    local cpufreq_table_rows = on("compute", "cpufreq_table") and cpufreq_rows(snapshot, format) or {}
    local sensor_table_rows = on("compute", "sensor_table") and sensor_rows(snapshot, format) or {}
    local power_table_rows = on("compute", "power_table") and power_rows(snapshot, format) or {}
    local mount_table_rows, mounts_hidden = {}, 0
    if on("storage", "mount_table") then
        mount_table_rows, mounts_hidden = mount_rows(snapshot, format,
            { show_pseudo = options.show_pseudo_filesystems })
    end
    local workload_table_rows = on("workloads", "workload_table") and workload_rows(snapshot, format) or {}

    local average_frequency = Engine.average_cpu_frequency(snapshot.cpu_frequency)
    local maximum_temperature = Engine.maximum_temperature(snapshot.sensors)
    local cpu_power = snapshot.power and snapshot.power.total_power_watts
    local workload_root = snapshot.workloads and snapshot.workloads.summary
        and snapshot.workloads.summary.root
    local battery_summary = snapshot.power_supplies and snapshot.power_supplies.summary

    local percent_axis = function(value) return string.format("%d%%", math.floor(value + 0.5)) end
    local rate_axis = function(value) return rate(format, value) end

    local function history(key) return engine:history_values(key) end

    local models = {
        -- Overview -------------------------------------------------------
        cpu_overview = {
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
            axis_format = function(value) return string.format("%.0fW", value) end,
        },

        -- Processes ------------------------------------------------------
        process_table = {
            panel_title = translated(i18n, "widgets.processes_sorted",
                "Processes · {sort} {direction}", {
                    sort = process_sort_label(i18n, process_status.sort_key),
                    direction = translated(i18n, process_status.descending
                        and "process.direction.descending" or "process.direction.ascending",
                        process_status.descending and "descending" or "ascending"),
                }),
            columns = {
                { key = "pid", label = "PID", sort_key = "pid",
                    width = 8, min_width = 5, priority = 90, align = "right",
                    highlight = true },
                { key = "user", label = translated(i18n, "metrics.user", "User"),
                    sort_key = "user", width = 12, min_width = 8, priority = 55,
                    highlight = true },
                { key = "priority", label = "PRI", width = 4, min_width = 3,
                    align = "right", priority = 20, full_only = true },
                { key = "nice", label = "NI", width = 4, min_width = 3,
                    align = "right", priority = 22, full_only = true },
                { key = "virtual_memory", label = translated(i18n, "metrics.virtual", "Virt"),
                    sort_key = "virtual", width = 10, min_width = 8,
                    align = "right", priority = 35, full_only = true },
                { key = "memory", label = translated(i18n, "metrics.memory", "Res"),
                    sort_key = "memory", width = 10, min_width = 8, align = "right", priority = 80,
                    token = function(_, row)
                        return severity_token(row.memory_fraction and row.memory_fraction * 100, 10, 25)
                    end,
                    bar = function(_, row) return row.memory_fraction end },
                { key = "state", label = "S", width = 3, min_width = 3, priority = 45,
                    sort_key = "state",
                    token = function(value)
                        if value == "R" then return "metric.good" end
                        if value == "D" then return "metric.critical" end
                        if value == "Z" then return "metric.warn" end
                        return nil
                    end },
                { key = "cpu", label = "CPU", sort_key = "cpu",
                    width = 9, min_width = 7, align = "right", priority = 95,
                    token = function(_, row) return severity_token(row.cpu_value, 40, 80) end,
                    bar = function(_, row)
                        return row.cpu_value and math.min(1, row.cpu_value / 100) or nil
                    end },
                { key = "time", label = "TIME+", sort_key = "time",
                    width = 10, min_width = 8, align = "right", priority = 40 },
                { key = "threads", label = translated(i18n, "metrics.threads", "Thr"),
                    sort_key = "threads", width = 5, min_width = 4,
                    align = "right", priority = 25, full_only = true },
                { key = "name", label = translated(i18n, "metrics.command", "Command"),
                    sort_key = "name", width = 40, min_width = 12, priority = 85,
                    highlight = true },
            },
            rows = process_rows,
            highlights = process_status.query_highlights,
            selected = process_status.selected_index,
            sort_key = process_status.sort_key,
            sort_descending = process_status.descending,
            status = process_status,
            status_text = process_status_display,
        },

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
                { key = "core", label = "CPU", width = 8, min_width = 5, priority = 90 },
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
                { key = "current", label = translated(i18n, "metrics.current", "Current"), width = 13, min_width = 9, align = "right", priority = 95 },
                { key = "minimum", label = translated(i18n, "metrics.minimum", "Minimum"), width = 12, min_width = 9, align = "right", priority = 50 },
                { key = "maximum", label = translated(i18n, "metrics.maximum", "Maximum"), width = 12, min_width = 9, align = "right", priority = 60 },
                { key = "governor", label = translated(i18n, "metrics.governor", "Governor"), width = 14, min_width = 9, priority = 65 },
                { key = "driver", label = translated(i18n, "metrics.driver", "Driver"), width = 16, min_width = 9, priority = 20, full_only = true },
            },
            rows = cpufreq_table_rows,
        },
        sensor_table = {
            columns = {
                { key = "device", label = translated(i18n, "metrics.device", "Device"), width = 16, min_width = 9, priority = 80 },
                { key = "sensor", label = translated(i18n, "metrics.sensor", "Sensor"), width = 22, min_width = 12, priority = 90 },
                { key = "value", label = translated(i18n, "metrics.value", "Value"), width = 14, min_width = 9, align = "right", priority = 95 },
                { key = "status", label = translated(i18n, "metrics.state", "State"), width = 12, min_width = 8, priority = 60,
                    token = function(value) return value == "ALARM" or value == "FAULT"
                        and "metric.critical" or nil end },
            },
            rows = sensor_table_rows,
        },
        power_table = {
            columns = {
                { key = "zone", label = translated(i18n, "metrics.device", "Zone"), width = 18, min_width = 10, priority = 90 },
                { key = "domain", label = translated(i18n, "metrics.type", "Domain"), width = 15, min_width = 9, priority = 70 },
                { key = "power", label = translated(i18n, "metrics.power", "Power"), width = 12, min_width = 9, align = "right", priority = 95 },
                { key = "energy", label = translated(i18n, "metrics.energy", "Energy"), width = 14, min_width = 9, align = "right", priority = 50 },
                { key = "limit", label = translated(i18n, "metrics.maximum", "Limit"), width = 12, min_width = 9, align = "right", priority = 60 },
                { key = "source", label = translated(i18n, "metrics.source", "Source"), width = 14, min_width = 9, priority = 20, full_only = true },
                { key = "state", label = translated(i18n, "metrics.state", "State"), width = 11, min_width = 8, priority = 25, full_only = true },
            },
            rows = power_table_rows,
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
            columns = {
                { key = "device", label = translated(i18n, "metrics.device", "Device"), width = 12, min_width = 8, priority = 95 },
                { key = "model", label = translated(i18n, "metrics.model", "Model"), width = 20, min_width = 10, priority = 40, full_only = true },
                { key = "size", label = translated(i18n, "metrics.capacity", "Size"), width = 10, min_width = 8, align = "right", priority = 55 },
                { key = "medium", label = translated(i18n, "metrics.medium", "Type"), width = 5, min_width = 4, priority = 30, full_only = true },
                { key = "read", label = translated(i18n, "metrics.read", "Read"), width = 12, min_width = 10, align = "right", priority = 90 },
                { key = "write", label = translated(i18n, "metrics.write", "Write"), width = 12, min_width = 10, align = "right", priority = 88 },
                { key = "busy", label = translated(i18n, "metrics.busy", "Busy"), width = 9, min_width = 7, align = "right", priority = 70,
                    token = function(_, row) return severity_token(row.busy_value, 60, 85) end,
                    bar = function(_, row)
                        return row.busy_value and math.min(1, row.busy_value / 100) or nil
                    end },
                { key = "queue", label = translated(i18n, "metrics.queue", "Queue"), width = 7, min_width = 6, align = "right", priority = 25, full_only = true },
                { key = "latency", label = translated(i18n, "metrics.read_latency", "Read latency"), width = 13, min_width = 10, align = "right", priority = 35, full_only = true },
            },
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
                { key = "readonly", label = "RW", width = 3, min_width = 2, priority = 20, full_only = true },
                { key = "source", label = translated(i18n, "metrics.source", "Source"), width = 22, min_width = 10, priority = 25, full_only = true },
            },
            rows = mount_table_rows,
            status_text = mounts_hidden > 0 and translated(i18n, "storage.hidden_mounts",
                "{count} pseudo filesystems hidden", { count = mounts_hidden }) or nil,
        },
        smart_hint = { entries = smart_hint_entries(snapshot, capabilities, i18n) },

        -- Network --------------------------------------------------------
        network_summary = {
            label = translated(i18n, "metrics.network", "Network"),
            display_value = "↓ " .. rate(format, network_receive) .. "  ↑ " .. rate(format, network_transmit),
            history = history("network_receive"), quality = quality(snapshot, "network"),
            axis_format = rate_axis,
        },
        network_table = {
            columns = {
                { key = "interface", label = translated(i18n, "metrics.interface", "Interface"), width = 12, min_width = 8, priority = 95 },
                { key = "state", label = translated(i18n, "metrics.state", "State"), width = 9, min_width = 7, priority = 70,
                    token = function(value)
                        if value == "up" then return "metric.good" end
                        if value == "down" then return "metric.critical" end
                        return nil
                    end },
                { key = "receive", label = translated(i18n, "metrics.receive", "Receive"), width = 12, min_width = 10, align = "right", priority = 92 },
                { key = "transmit", label = translated(i18n, "metrics.transmit", "Transmit"), width = 12, min_width = 10, align = "right", priority = 90 },
                { key = "speed", label = translated(i18n, "metrics.link", "Link"), width = 12, min_width = 9, align = "right", priority = 40 },
                { key = "mtu", label = "MTU", width = 6, min_width = 5, align = "right", priority = 35 },
                { key = "mac", label = "MAC", width = 18, min_width = 17, priority = 25, full_only = true },
                { key = "errors", label = translated(i18n, "metrics.errors", "Err"), width = 6, min_width = 5, align = "right", priority = 30,
                    token = function(_, row)
                        return (row.error_value or 0) > 0 and "metric.warn" or nil
                    end },
            },
            rows = interfaces,
        },
        address_table = {
            columns = {
                { key = "interface", label = translated(i18n, "metrics.interface", "Interface"), width = 12, min_width = 8, priority = 90 },
                { key = "family", label = translated(i18n, "metrics.family", "Family"), width = 6, min_width = 5, priority = 70 },
                { key = "address", label = translated(i18n, "metrics.address", "Address"), width = 30, min_width = 14, priority = 95 },
                { key = "netmask", label = translated(i18n, "metrics.netmask", "Netmask"), width = 20, min_width = 12, priority = 40, full_only = true },
                { key = "default_route", label = translated(i18n, "metrics.default_route", "Default"), width = 8, min_width = 7, priority = 50 },
            },
            rows = addresses,
            status_text = snapshot.network and snapshot.network.addresses_status
                and snapshot.network.addresses_status ~= "ok"
                and tostring(snapshot.network.addresses_status) or nil,
        },
        connection_table = {
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
                    quality = snapshot.connections and snapshot.connections.owner_scan
                        and snapshot.connections.owner_scan.status or "unavailable",
                }),
        },

        -- GPU ------------------------------------------------------------
        gpu_summary = {
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
                { key = "vendor", label = translated(i18n, "metrics.vendor", "Vendor"), width = 16, min_width = 8, priority = 50 },
                { key = "driver", label = translated(i18n, "metrics.driver", "Driver"), width = 12, min_width = 8, priority = 45 },
                { key = "utilization", label = translated(i18n, "metrics.utilization", "Util"), width = 9, min_width = 7, align = "right", priority = 90 },
                { key = "memory", label = translated(i18n, "metrics.memory", "Memory"), width = 20, min_width = 12, align = "right", priority = 85 },
                { key = "frequency", label = translated(i18n, "metrics.frequency", "Frequency"), width = 13, min_width = 9, align = "right", priority = 35, full_only = true },
                { key = "pcie", label = "PCIe", width = 18, min_width = 9, priority = 25, full_only = true },
                { key = "temperature", label = translated(i18n, "metrics.temperature", "Temp"), width = 9, min_width = 7, align = "right", priority = 70 },
                { key = "power", label = translated(i18n, "metrics.power", "Power"), width = 10, min_width = 8, align = "right", priority = 40, full_only = true },
            },
            rows = gpu_table_rows,
        },
        gpu_process_table = {
            columns = {
                { key = "gpu", label = "GPU", width = 10, min_width = 6, priority = 70 },
                { key = "pid", label = "PID", width = 8, min_width = 6, align = "right", priority = 80 },
                { key = "process", label = translated(i18n, "metrics.process", "Process"), width = 22, min_width = 10, priority = 95 },
                { key = "utilization", label = translated(i18n, "metrics.utilization", "Utilization"), width = 12, min_width = 8, align = "right", priority = 90 },
                { key = "memory", label = translated(i18n, "metrics.memory", "Memory"), width = 14, min_width = 10, align = "right", priority = 85 },
                { key = "engines", label = translated(i18n, "metrics.engines", "Engines"), width = 30, min_width = 12, priority = 25, full_only = true },
                { key = "quality", label = translated(i18n, "inspector.quality", "Quality"), width = 11, min_width = 8, priority = 20, full_only = true },
            },
            rows = gpu_process_table_rows,
            status_text = translated(i18n, "gpu.process_status",
                "GPU processes: {visible}/{total} · scan {quality}", {
                    visible = #gpu_process_table_rows,
                    total = gpu_process_total,
                    quality = snapshot.gpus and snapshot.gpus.process_scan
                        and (snapshot.gpus.process_scan.quality or snapshot.gpus.process_scan.status)
                        or "unavailable",
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
                { key = "pressure", label = translated(i18n, "metrics.pressure", "Pressure"), width = 9, min_width = 7, align = "right", priority = 30, full_only = true },
                { key = "quality", label = translated(i18n, "inspector.quality", "Quality"), width = 10, min_width = 8, priority = 22, full_only = true },
            },
            rows = workload_table_rows,
        },
        workload_detail = { entries = workload_detail_entries(snapshot, format, i18n) },

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

        -- Insights -------------------------------------------------------
        collector_table = {
            columns = {
                { key = "collector", label = translated(i18n, "insights.collector", "Collector"), width = 14, min_width = 10, priority = 95 },
                { key = "status", label = translated(i18n, "metrics.state", "State"), width = 13, min_width = 9, priority = 90,
                    token = function(_, row)
                        if not row.available then return "text.muted" end
                        if row.status == "denied" or row.status == "error" then return "metric.critical" end
                        return "metric.good"
                    end },
                { key = "quality", label = translated(i18n, "inspector.quality", "Quality"), width = 11, min_width = 8, priority = 70 },
                { key = "source", label = translated(i18n, "metrics.source", "Source"), width = 34, min_width = 12, priority = 50 },
                { key = "reason", label = translated(i18n, "inspector.reason", "Reason"), width = 28, min_width = 10, priority = 30, full_only = true },
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
                { key = "status", label = translated(i18n, "metrics.state", "State"), width = 12, min_width = 9, priority = 90,
                    token = function(_, row) return row.available and "metric.good" or "text.muted" end },
                { key = "reason", label = translated(i18n, "inspector.reason", "Reason"), width = 26, min_width = 10, priority = 40, full_only = true },
            },
            rows = inspector_rows(capabilities, i18n),
        },
        advice_list = {
            entries = advice_entries(snapshot, capabilities, i18n,
                options.privilege, linux_host),
        },
    }
    return models
end

return M
