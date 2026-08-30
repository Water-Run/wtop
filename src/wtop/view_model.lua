local Engine = require("wtop.engine")
local ProcessTable = require("wtop.model.process_table")

local M = {}
local EMPTY_PROCESS_SOURCE = {}
local PROCESS_VIEW_CACHE = setmetatable({}, { __mode = "k" })
local TABLE_ROW_LIMIT = 512

local function bounded_best_values(values, limit, better)
    local heap = {}
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
    for _, value in ipairs(values or {}) do
        if #heap < limit then
            heap[#heap + 1] = value
            sift_up(#heap)
        elseif better(value, heap[1]) then
            heap[1] = value
            sift_down(1)
        end
    end
    table.sort(heap, better)
    return heap
end

local function translated(i18n, id, fallback, variables)
    local value = i18n and i18n:t(id, variables)
    return value and value ~= id and value or fallback
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
    for _, process in ipairs(controller:rows()) do
        local name = process.command or process.name or "?"
        if status.tree then
            local prefix = string.rep("  ", math.min(process.tree_depth or 0, status.max_tree_depth or 64))
            name = prefix .. (process.tree_has_children and "▾ " or "· ") .. name
        end
        rows[#rows + 1] = {
            id = process.id,
            pid = tostring(process.pid),
            name = name,
            cpu = process.cpu_percent and percent(format, process.cpu_percent) or "—",
            memory = bytes(format, process.resident_bytes),
            state = process.state or "?",
            user = process.user or (process.uid and tostring(process.uid)) or "—",
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
            user = percent(format, core.user),
            system = percent(format, core.system),
            iowait = percent(format, core.iowait),
        }
    end
    return rows
end

local function disk_rows(snapshot, format)
    local rows = {}
    for _, device in ipairs(snapshot.disks and snapshot.disks.devices or {}) do
        rows[#rows + 1] = {
            device = device.name,
            read = rate(format, device.read_bytes_per_second),
            write = rate(format, device.write_bytes_per_second),
            busy = percent(format, device.busy_percent),
            latency = device.average_read_latency_ms
                and formatted(function() return assert(format:number(device.average_read_latency_ms, { precision = 1 })) end) .. " ms"
                or "—",
        }
    end
    return rows
end

local function network_rows(snapshot, format)
    local rows = {}
    for _, interface in ipairs(snapshot.network and snapshot.network.interfaces or {}) do
        rows[#rows + 1] = {
            interface = interface.name,
            state = interface.operstate or "?",
            receive = rate(format, interface.rates and interface.rates.rx_bytes_per_second),
            transmit = rate(format, interface.rates and interface.rates.tx_bytes_per_second),
            speed = interface.speed_mbps and (tostring(interface.speed_mbps) .. " Mbit/s") or "—",
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
        rows[#rows + 1] = {
            gpu = gpu.card or gpu.id,
            vendor = gpu.vendor or "?",
            driver = gpu.driver or "?",
            utilization = percent(format, metrics.utilization_percent),
            memory = metrics.memory_used_bytes and (bytes(format, metrics.memory_used_bytes)
                .. " / " .. bytes(format, metrics.memory_total_bytes)) or "—",
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
    for _, device in ipairs(snapshot.sensors and snapshot.sensors.devices or {}) do
        for _, channel in ipairs(device.channels or {}) do
            rows[#rows + 1] = {
                device = device.name or device.class or "?",
                sensor = channel.label or (channel.type .. " " .. tostring(channel.index)),
                type = channel.type,
                value = sensor_value(channel, format),
                status = channel.fault and "FAULT" or (channel.alarm and "ALARM" or channel.quality or "—"),
                alarm = channel.alarm == true or channel.fault == true,
            }
        end
    end
    table.sort(rows, function(left, right)
        if left.alarm ~= right.alarm then return left.alarm end
        if left.device == right.device then return left.sensor < right.sensor end
        return left.device < right.device
    end)
    return rows
end

local function mount_rows(snapshot, format)
    local rank = { ["local"] = 1, network = 2, pseudo = 3 }
    local selected = bounded_best_values(snapshot.mounts and snapshot.mounts.mounts or {}, TABLE_ROW_LIMIT,
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
        rows[#rows + 1] = {
            mount = mount.mount_point,
            type = mount.fs_type,
            used = percent(format, capacity.used_percent),
            available = bytes(format, capacity.available_bytes),
            size = bytes(format, capacity.total_bytes),
            source = mount.source or "—",
            kind = mount.kind or "?",
            readonly = mount.readonly and "ro" or "rw",
        }
    end
    return rows
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

function M.build(engine, snapshot, i18n, capabilities, active_tab, process_controller, visible_widgets)
    local format = i18n.format
    local function visible(widget_id)
        return type(visible_widgets) ~= "table" or visible_widgets[widget_id] == true
    end
    local cpu_value = snapshot.cpu and snapshot.cpu.total and snapshot.cpu.total.utilization
    local memory_value
    if snapshot.memory and snapshot.memory.total_bytes and snapshot.memory.total_bytes > 0 then
        memory_value = snapshot.memory.used_bytes * 100 / snapshot.memory.total_bytes
    end
    local pressure = Engine.pressure_value(snapshot.pressure)
    local disk_read = Engine.sum_devices(snapshot.disks and snapshot.disks.devices, "read_bytes_per_second")
    local disk_write = Engine.sum_devices(snapshot.disks and snapshot.disks.devices, "write_bytes_per_second")
    local network_receive = Engine.sum_interfaces(snapshot.network and snapshot.network.interfaces, "rx_bytes_per_second")
    local network_transmit = Engine.sum_interfaces(snapshot.network and snapshot.network.interfaces, "tx_bytes_per_second")
    local gpu_devices = snapshot.gpus and snapshot.gpus.devices or {}
    local first_gpu = gpu_devices[1] and gpu_devices[1].metrics or {}
    local process_count = snapshot.processes and snapshot.processes.process_candidates
        or #(snapshot.processes and snapshot.processes.list or {})
    local process_rows, process_status, process_status_display
    if (not active_tab or active_tab == "processes") and visible("process_table") then
        process_controller = process_controller or ProcessTable.new()
        process_rows, process_status, process_status_display = top_processes(
            snapshot, format, process_controller, i18n)
    else
        process_rows = {}
        process_status = process_controller and process_controller:status() or ProcessTable.new():status()
        process_status_display = process_status_text(i18n, process_status)
    end
    local cores = (not active_tab or active_tab == "compute") and visible("core_table")
        and core_rows(snapshot, format) or {}
    local disks = (not active_tab or active_tab == "storage") and visible("disk_table")
        and disk_rows(snapshot, format) or {}
    local interfaces = (not active_tab or active_tab == "network") and visible("network_table")
        and network_rows(snapshot, format) or {}
    local connections = (not active_tab or active_tab == "network") and visible("connection_table")
        and connection_rows(snapshot) or {}
    local gpu_table_rows = (not active_tab or active_tab == "gpu") and visible("gpu_table")
        and gpu_rows(snapshot, format) or {}
    local gpu_process_table_rows, gpu_process_total = {}, 0
    if (not active_tab or active_tab == "gpu") and visible("gpu_process_table") then
        gpu_process_table_rows, gpu_process_total = gpu_process_rows(snapshot, format)
    end
    local cpufreq_table_rows = (not active_tab or active_tab == "compute") and visible("cpufreq_table")
        and cpufreq_rows(snapshot, format) or {}
    local sensor_table_rows = (not active_tab or active_tab == "compute") and visible("sensor_table")
        and sensor_rows(snapshot, format) or {}
    local mount_table_rows = (not active_tab or active_tab == "storage") and visible("mount_table")
        and mount_rows(snapshot, format) or {}
    local workload_table_rows = (not active_tab or active_tab == "workloads") and visible("workload_table")
        and workload_rows(snapshot, format) or {}
    local average_frequency = Engine.average_cpu_frequency(snapshot.cpu_frequency)
    local maximum_temperature = Engine.maximum_temperature(snapshot.sensors)
    local workload_root = snapshot.workloads and snapshot.workloads.summary
        and snapshot.workloads.summary.root

    local models = {
        cpu_overview = {
            label = translated(i18n, "metrics.cpu", "CPU"),
            value = cpu_value,
            display_value = percent(format, cpu_value),
            history = engine:history_values("cpu"),
            quality = quality(snapshot, "cpu"), min = 0, max = 100,
        },
        memory_overview = {
            label = translated(i18n, "metrics.memory", "Memory"),
            value = memory_value,
            display_value = percent(format, memory_value),
            history = engine:history_values("memory"),
            quality = quality(snapshot, "memory"), min = 0, max = 100,
        },
        pressure_overview = {
            label = translated(i18n, "metrics.pressure", "Pressure"),
            value = pressure,
            display_value = percent(format, pressure),
            history = engine:history_values("pressure"),
            quality = quality(snapshot, "pressure"), min = 0, max = 100,
        },
        disk_overview = {
            label = translated(i18n, "metrics.disk_io", "Disk I/O"),
            display_value = "↓ " .. rate(format, disk_read) .. "  ↑ " .. rate(format, disk_write),
            history = engine:history_values("disk_read"), quality = quality(snapshot, "disks"),
        },
        network_overview = {
            label = translated(i18n, "metrics.network_io", "Network I/O"),
            display_value = "↓ " .. rate(format, network_receive) .. "  ↑ " .. rate(format, network_transmit),
            history = engine:history_values("network_receive"), quality = quality(snapshot, "network"),
        },
        gpu_overview = {
            label = translated(i18n, "metrics.gpu", "GPU"),
            value = first_gpu.utilization_percent,
            display_value = #gpu_devices == 0 and translated(i18n, "ui.no_data", "No data")
                or percent(format, first_gpu.utilization_percent),
            history = engine:history_values("gpu"), quality = quality(snapshot, "gpus"), min = 0, max = 100,
        },
        frequency_overview = {
            label = translated(i18n, "metrics.frequency", "Frequency"),
            display_value = frequency(format, average_frequency),
            history = engine:history_values("cpu_frequency"), quality = quality(snapshot, "cpu_frequency"),
        },
        temperature_overview = {
            label = translated(i18n, "metrics.temperature", "Temperature"),
            display_value = temperature(format, maximum_temperature),
            history = engine:history_values("temperature"), quality = quality(snapshot, "sensors"),
        },
        process_table = {
            columns = {
                { key = "pid", label = "PID" .. (process_status.sort_key == "pid"
                    and (process_status.descending and " ↓" or " ↑") or ""), width = 8, min_width = 5 },
                { key = "name", label = translated(i18n, "metrics.processes", "Process")
                    .. (process_status.sort_key == "name" and (process_status.descending and " ↓" or " ↑") or ""),
                    width = 36, min_width = 12 },
                { key = "cpu", label = "CPU" .. (process_status.sort_key == "cpu"
                    and (process_status.descending and " ↓" or " ↑") or ""),
                    width = 10, min_width = 8, align = "right" },
                { key = "memory", label = translated(i18n, "metrics.memory", "Memory")
                    .. (process_status.sort_key == "memory" and (process_status.descending and " ↓" or " ↑") or ""),
                    width = 12, min_width = 9, align = "right" },
                { key = "state", label = "S", width = 3, min_width = 3, full_only = true },
                { key = "user", label = translated(i18n, "metrics.user", "User"), width = 12, min_width = 8, full_only = true },
            },
            rows = process_rows,
            selected = process_status.selected_index,
            status = process_status,
            status_text = process_status_display,
        },
        cpu_total = {
            label = translated(i18n, "metrics.utilization", "Utilization"),
            value = cpu_value,
            display_value = percent(format, cpu_value),
            history = engine:history_values("cpu"), quality = quality(snapshot, "cpu"), min = 0, max = 100,
        },
        load_summary = {
            text = snapshot.cpu and snapshot.cpu.load and string.format(
                "1m  %.2f\n5m  %.2f\n15m %.2f\n%s %s",
                snapshot.cpu.load.one or 0, snapshot.cpu.load.five or 0, snapshot.cpu.load.fifteen or 0,
                translated(i18n, "metrics.running", "Running"),
                tostring(snapshot.cpu.processes_running or "—")
            ) or translated(i18n, "ui.no_data", "No data"),
        },
        core_table = {
            columns = {
                { key = "core", label = "CPU", width = 8, min_width = 5 },
                { key = "total", label = translated(i18n, "metrics.total", "Total"), width = 10, min_width = 8, align = "right" },
                { key = "user", label = translated(i18n, "metrics.user", "User"), width = 10, min_width = 8, align = "right" },
                { key = "system", label = translated(i18n, "metrics.system", "System"), width = 10, min_width = 8, align = "right" },
                { key = "iowait", label = translated(i18n, "metrics.iowait", "I/O wait"), width = 10, min_width = 8, align = "right" },
            },
            rows = cores,
        },
        cpufreq_table = {
            columns = {
                { key = "policy", label = translated(i18n, "metrics.policy", "Policy"), width = 10, min_width = 8 },
                { key = "cpus", label = "CPU", width = 12, min_width = 6 },
                { key = "current", label = translated(i18n, "metrics.current", "Current"), width = 13, min_width = 9, align = "right" },
                { key = "minimum", label = translated(i18n, "metrics.minimum", "Minimum"), width = 12, min_width = 9, align = "right" },
                { key = "maximum", label = translated(i18n, "metrics.maximum", "Maximum"), width = 12, min_width = 9, align = "right" },
                { key = "governor", label = translated(i18n, "metrics.governor", "Governor"), width = 14, min_width = 9 },
                { key = "driver", label = translated(i18n, "metrics.driver", "Driver"), width = 16, min_width = 9, full_only = true },
            },
            rows = cpufreq_table_rows,
        },
        sensor_table = {
            columns = {
                { key = "device", label = translated(i18n, "metrics.device", "Device"), width = 16, min_width = 9 },
                { key = "sensor", label = translated(i18n, "metrics.sensor", "Sensor"), width = 22, min_width = 12 },
                { key = "value", label = translated(i18n, "metrics.value", "Value"), width = 14, min_width = 9, align = "right" },
                { key = "status", label = translated(i18n, "metrics.state", "State"), width = 12, min_width = 8 },
            },
            rows = sensor_table_rows,
        },
        memory_detail = {
            text = table.concat({
                translated(i18n, "metrics.used", "Used") .. "       "
                    .. bytes(format, snapshot.memory and snapshot.memory.used_bytes),
                translated(i18n, "metrics.available", "Available") .. "  "
                    .. bytes(format, snapshot.memory and snapshot.memory.available_bytes),
                translated(i18n, "metrics.cache", "Cache") .. "      "
                    .. bytes(format, snapshot.memory and snapshot.memory.cache_bytes),
                translated(i18n, "metrics.swap", "Swap") .. "       "
                    .. bytes(format, snapshot.memory and snapshot.memory.swap_used_bytes)
                    .. " / " .. bytes(format, snapshot.memory and snapshot.memory.swap_total_bytes),
            }, "\n"),
        },
        storage_summary = {
            label = translated(i18n, "metrics.storage", "Storage"),
            display_value = "↓ " .. rate(format, disk_read) .. "  ↑ " .. rate(format, disk_write),
            history = engine:history_values("disk_read"), quality = quality(snapshot, "disks"),
        },
        disk_table = {
            columns = {
                { key = "device", label = translated(i18n, "metrics.device", "Device"), width = 14, min_width = 8 },
                { key = "read", label = translated(i18n, "metrics.read", "Read"), width = 14, min_width = 10, align = "right" },
                { key = "write", label = translated(i18n, "metrics.write", "Write"), width = 14, min_width = 10, align = "right" },
                { key = "busy", label = translated(i18n, "metrics.busy", "Busy"), width = 10, min_width = 8, align = "right" },
                { key = "latency", label = translated(i18n, "metrics.read_latency", "Read latency"), width = 14,
                    min_width = 10, align = "right", full_only = true },
            },
            rows = disks,
        },
        mount_table = {
            columns = {
                { key = "mount", label = translated(i18n, "metrics.mount", "Mount"), width = 28, min_width = 12 },
                { key = "type", label = translated(i18n, "metrics.filesystem", "Filesystem"), width = 12, min_width = 8 },
                { key = "used", label = translated(i18n, "metrics.used", "Used"), width = 10, min_width = 8, align = "right" },
                { key = "available", label = translated(i18n, "metrics.available", "Available"), width = 14, min_width = 10, align = "right" },
                { key = "size", label = translated(i18n, "metrics.total", "Total"), width = 14, min_width = 10, align = "right" },
                { key = "source", label = translated(i18n, "metrics.source", "Source"), width = 24, min_width = 10, full_only = true },
            },
            rows = mount_table_rows,
        },
        smart_hint = {
            text = translated(i18n, "storage.smart_hint",
                    "SMART/NVMe inspector: press s to choose a device.") .. "\n"
                .. translated(i18n, "storage.smart_standby",
                    "Read-only probes are lazy; standby disks are not awakened."),
            muted = true,
        },
        network_summary = {
            label = translated(i18n, "metrics.network", "Network"),
            display_value = "↓ " .. rate(format, network_receive) .. "  ↑ " .. rate(format, network_transmit),
            history = engine:history_values("network_receive"), quality = quality(snapshot, "network"),
        },
        network_table = {
            columns = {
                { key = "interface", label = translated(i18n, "metrics.interface", "Interface"), width = 14, min_width = 8 },
                { key = "state", label = translated(i18n, "metrics.state", "State"), width = 10, min_width = 7 },
                { key = "receive", label = translated(i18n, "metrics.receive", "Receive"), width = 14, min_width = 10, align = "right" },
                { key = "transmit", label = translated(i18n, "metrics.transmit", "Transmit"), width = 14, min_width = 10, align = "right" },
                { key = "speed", label = translated(i18n, "metrics.link", "Link"), width = 14, min_width = 10,
                    align = "right", full_only = true },
            },
            rows = interfaces,
        },
        connection_table = {
            columns = {
                { key = "protocol", label = translated(i18n, "metrics.protocol", "Proto"), width = 7, min_width = 5 },
                { key = "local_endpoint", label = translated(i18n, "metrics.local_endpoint", "Local"), width = 28, min_width = 14 },
                { key = "remote_endpoint", label = translated(i18n, "metrics.remote_endpoint", "Remote"), width = 30, min_width = 14 },
                { key = "state", label = translated(i18n, "metrics.state", "State"), width = 14, min_width = 8 },
                { key = "process", label = translated(i18n, "metrics.process", "Process"), width = 24, min_width = 10 },
                { key = "queue", label = translated(i18n, "metrics.queue", "Queue"), width = 10, min_width = 7,
                    align = "right", full_only = true },
                { key = "uid", label = "UID", width = 8, min_width = 6, align = "right", full_only = true },
            },
            rows = connections,
            status_text = translated(i18n, "network.connection_status",
                "{count} sockets · owner mapping {quality}", {
                    count = snapshot.connections and snapshot.connections.total or #connections,
                    quality = snapshot.connections and snapshot.connections.owner_scan
                        and snapshot.connections.owner_scan.status or "unavailable",
                }),
        },
        gpu_summary = {
            label = translated(i18n, "metrics.gpu", "GPU"),
            value = first_gpu.utilization_percent,
            display_value = #gpu_devices == 0 and translated(i18n, "ui.no_data", "No data")
                or percent(format, first_gpu.utilization_percent),
            history = engine:history_values("gpu"), quality = quality(snapshot, "gpus"), min = 0, max = 100,
        },
        gpu_table = {
            columns = {
                { key = "gpu", label = "GPU", width = 10, min_width = 6 },
                { key = "vendor", label = translated(i18n, "metrics.vendor", "Vendor"), width = 10, min_width = 8 },
                { key = "driver", label = translated(i18n, "metrics.driver", "Driver"), width = 12, min_width = 8 },
                { key = "utilization", label = translated(i18n, "metrics.utilization", "Util"), width = 10, min_width = 8,
                    align = "right" },
                { key = "memory", label = "VRAM", width = 20, min_width = 12, align = "right" },
                { key = "temperature", label = translated(i18n, "metrics.temperature", "Temp"), width = 10,
                    min_width = 8, align = "right" },
                { key = "power", label = translated(i18n, "metrics.power", "Power"), width = 10, min_width = 8,
                    align = "right", full_only = true },
            },
            rows = gpu_table_rows,
        },
        gpu_process_table = {
            columns = {
                { key = "gpu", label = "GPU", width = 10, min_width = 6 },
                { key = "pid", label = "PID", width = 8, min_width = 6, align = "right" },
                { key = "process", label = translated(i18n, "metrics.process", "Process"), width = 22, min_width = 10 },
                { key = "utilization", label = translated(i18n, "metrics.utilization", "Utilization"),
                    width = 12, min_width = 8, align = "right" },
                { key = "memory", label = translated(i18n, "metrics.memory", "Memory"),
                    width = 14, min_width = 10, align = "right" },
                { key = "engines", label = translated(i18n, "metrics.engines", "Engines"),
                    width = 34, min_width = 12, full_only = true },
                { key = "quality", label = translated(i18n, "inspector.quality", "Quality"),
                    width = 11, min_width = 8, full_only = true },
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
        workload_summary = {
            label = translated(i18n, "metrics.workloads", "Workloads"),
            value = workload_root and workload_root.cpu_utilization_percent,
            display_value = workload_root and percent(format, workload_root.cpu_utilization_percent)
                or translated(i18n, "ui.no_data", "No data"),
            history = engine:history_values("workload_cpu"), quality = quality(snapshot, "workloads"),
            min = 0, max = 100,
        },
        workload_table = {
            columns = {
                { key = "workload", label = translated(i18n, "metrics.workload", "Workload"), width = 38, min_width = 14 },
                { key = "cpu", label = "CPU", width = 10, min_width = 8, align = "right" },
                { key = "memory", label = translated(i18n, "metrics.memory", "Memory"), width = 13, min_width = 9, align = "right" },
                { key = "read", label = translated(i18n, "metrics.read", "Read"), width = 13, min_width = 9, align = "right" },
                { key = "write", label = translated(i18n, "metrics.write", "Write"), width = 13, min_width = 9, align = "right" },
                { key = "processes", label = translated(i18n, "metrics.processes", "Processes"), width = 9, min_width = 7, align = "right" },
                { key = "pressure", label = translated(i18n, "metrics.pressure", "Pressure"), width = 10, min_width = 8, align = "right", full_only = true },
            },
            rows = workload_table_rows,
        },
        workload_detail = {
            text = table.concat({
                translated(i18n, "workloads.nodes", "Visible cgroups: {count}", {
                    count = snapshot.workloads and snapshot.workloads.summary
                        and snapshot.workloads.summary.node_count or 0,
                }),
                translated(i18n, "workloads.processes", "Visible processes: {count}", {
                    count = snapshot.workloads and snapshot.workloads.summary
                        and snapshot.workloads.summary.visible_process_count or 0,
                }),
                translated(i18n, "workloads.memory", "Root memory: {value}", {
                    value = bytes(format, workload_root and workload_root.memory_current_bytes),
                }),
                translated(i18n, "workloads.partial", "Partial cgroups: {count}", {
                    count = snapshot.workloads and snapshot.workloads.summary
                        and snapshot.workloads.summary.partial_node_count or 0,
                }),
            }, "\n"),
        },
        insight_summary = {
            text = table.concat({
                translated(i18n, "insights.collectors", "Collectors: {count} available", {
                    count = (function()
                        local count = 0
                        for _, capability in pairs(capabilities or {}) do
                            if capability.available then count = count + 1 end
                        end
                        return count
                    end)(),
                }),
                translated(i18n, "insights.processes", "Processes: {count}", { count = process_count }),
                translated(i18n, "insights.gpu_devices", "GPU devices: {count}", { count = #gpu_devices }),
                "",
                translated(i18n, "insights.deep_inspectors", "Deep inspectors"),
                "  " .. translated(i18n, "insights.smart", "SMART / NVMe health"),
                "  " .. translated(i18n, "insights.ram_bandwidth", "RAM bandwidth (PMU)"),
                "  " .. translated(i18n, "insights.sshd", "sshd service and listeners"),
            }, "\n"),
        },
    }
    return models
end

return M
