local Collectors = require("wtop.collectors")
local Ring = require("wtop.model.ring")
local Scheduler = require("wtop.core.scheduler")
local Snapshot = require("wtop.model.snapshot")
local Runner = require("wtop.core.runner")
local native = require("wtop.native")
local UpdateFrequency = require("wtop.update_frequency")

local Engine = {}
Engine.__index = Engine

local HISTORY_KEYS = {
    "cpu",
    "memory",
    "pressure",
    "disk_read",
    "disk_write",
    "network_receive",
    "network_transmit",
    "gpu",
    "cpu_frequency",
    "temperature",
    "workload_cpu",
}

-- One terminal column represented one second at the original default cadence.
-- Preserve that scale at every update rate, retaining up to the original
-- four-minute history for unusually wide charts.
local HISTORY_WINDOW_MS = 240000
local HISTORY_COLUMN_MS = 1000
local DEFAULT_HISTORY_CAPACITY = math.ceil(
    HISTORY_WINDOW_MS / UpdateFrequency.MIN_INTERVAL_MS) + 16

local INTERVAL_FLOORS_MS = {
    process = 1000,
    connections = 2000,
    gpu = 500,
    cpufreq = 1000,
    hwmon = 1000,
    mounts = 5000,
    cgroup = 2000,
}

-- Expensive and high-cardinality sources continue sampling while their page
-- is hidden, but at a lower cadence so histories stay meaningful without
-- making a system monitor consume the resources it is meant to observe.
local BACKGROUND_INTERVALS_MS = {
    cpu = 2000,
    memory = 5000,
    pressure = 2000,
    disk = 3000,
    network = 3000,
    connections = 10000,
    process = 5000,
    gpu = 5000,
    cpufreq = 5000,
    hwmon = 5000,
    mounts = 30000,
    cgroup = 10000,
}

local TAB_COLLECTORS = {
    overview = {
        cpu = true, memory = true, pressure = true, disk = true,
        network = true, gpu = true, cpufreq = true, hwmon = true,
    },
    processes = { cpu = true, memory = true, process = true },
    compute = { cpu = true, memory = true, pressure = true, cpufreq = true, hwmon = true },
    storage = { disk = true, mounts = true },
    network = { network = true, connections = true },
    gpu = { gpu = true, hwmon = true },
    workloads = { cpu = true, memory = true, pressure = true, cgroup = true },
    -- Insights is a static capability summary.  Its counts may use the bounded
    -- background samples; keeping the full process collector at 1 Hz here
    -- would burn a core merely to refresh a decorative count.
    insights = {},
}

-- The TUI may provide the widgets that survived responsive layout.  This
-- keeps collectors for collapsed panels on their background cadence and is
-- especially important for fdinfo/socket-owner scans on tiny terminals.
local TAB_WIDGET_COLLECTORS = {
    overview = {
        cpu_overview = { "cpu" }, memory_overview = { "memory" },
        pressure_overview = { "pressure" }, disk_overview = { "disk" },
        network_overview = { "network" }, gpu_overview = { "gpu" },
        frequency_overview = { "cpufreq" }, temperature_overview = { "hwmon" },
    },
    processes = { process_table = { "cpu", "memory", "process" } },
    compute = {
        cpu_total = { "cpu" }, load_summary = { "cpu" }, memory_detail = { "memory" },
        core_table = { "cpu" }, cpufreq_table = { "cpufreq" }, sensor_table = { "hwmon" },
    },
    storage = {
        storage_summary = { "disk" }, disk_table = { "disk" }, smart_hint = {},
        mount_table = { "mounts" },
    },
    network = {
        network_summary = { "network" }, network_table = { "network" },
        connection_table = { "connections" },
    },
    gpu = {
        gpu_summary = { "gpu" }, gpu_table = { "gpu", "hwmon" },
        gpu_process_table = { "gpu" },
    },
    workloads = {
        workload_summary = { "cgroup" }, workload_table = { "cgroup" },
        workload_detail = { "cgroup" },
    },
    insights = { insight_summary = {} },
}

local function finite_number(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function positive_integer(name, value, maximum)
    if type(value) ~= "number" or value ~= value
        or value == math.huge or value == -math.huge
        or value < 1 or value > maximum or value % 1 ~= 0
    then
        error(name .. " must be an integer in 1.." .. tostring(maximum), 3)
    end
    return value
end

local function valid_clock(clock)
    return type(clock) == "table" and type(clock.now_ns) == "function"
        and type(clock.wall_ns) == "function"
end

local function widget_visibility(tab_id, widget_ids)
    if type(widget_ids) ~= "table" then return TAB_COLLECTORS[tab_id] end
    local visible = {}
    for widget_id in pairs(widget_ids) do
        for _, collector_id in ipairs((TAB_WIDGET_COLLECTORS[tab_id] or {})[widget_id] or {}) do
            visible[collector_id] = true
        end
    end
    return visible
end

local function native_clock()
    return {
        now_ns = function()
            return native.monotonic_ns()
        end,
        wall_ns = function()
            return native.realtime_ns()
        end,
    }
end

local function sum_devices(devices, key)
    local total = 0
    local found = false
    for _, device in ipairs(devices or {}) do
        local value = device.aggregate ~= false and device[key] or nil
        if finite_number(value) then
            total = total + value
            if not finite_number(total) then return nil end
            found = true
        end
    end
    return found and total or nil
end

local function sum_interfaces(interfaces, key)
    local total = 0
    local found = false
    for _, interface in ipairs(interfaces or {}) do
        local value = interface.aggregate ~= false and interface.rates and interface.rates[key]
        if finite_number(value) then
            total = total + value
            if not finite_number(total) then return nil end
            found = true
        end
    end
    return found and total or nil
end

local function pressure_value(pressure)
    local cpu = pressure and pressure.cpu
    local some = cpu and cpu.some
    return some and (some.avg10 or some.avg60 or some.avg300) or nil
end

local function average_cpu_frequency(data)
    local total, weight = 0, 0
    for _, policy in ipairs(data and data.policies or {}) do
        local current = policy.frequencies and policy.frequencies.current_hz
      if finite_number(current) then
        local policy_weight = math.max(1, #(policy.affected_cpus or {}))
        total = total + current * policy_weight
        if not finite_number(total) then return nil end
        weight = weight + policy_weight
        end
    end
    return weight > 0 and total / weight or nil
end

local function maximum_temperature(data)
    local maximum
    for _, device in ipairs(data and data.devices or {}) do
        for _, channel in ipairs(device.channels or {}) do
            if channel.type == "temperature" and finite_number(channel.input) then
                maximum = maximum and math.max(maximum, channel.input) or channel.input
            end
        end
    end
    return maximum
end

function Engine.new(options)
    options = options or {}
    if type(options) ~= "table" then error("engine options must be a table", 2) end
    local clock = options.clock or native_clock()
    if not valid_clock(clock) then
        error("engine clock must provide now_ns and wall_ns", 2)
    end
    if options.interval_ms ~= nil then
        positive_integer("interval_ms", options.interval_ms, Scheduler.MAX_INTERVAL_MS)
    end
    if options.history_capacity ~= nil then
        positive_integer("history_capacity", options.history_capacity, 1000000)
    end
    if options.collectors ~= nil and type(options.collectors) ~= "table" then
        error("collectors must be a table", 2)
    end
    if options.context ~= nil and type(options.context) ~= "table" then
        error("context must be a table", 2)
    end
    if options.safe_mode ~= nil and type(options.safe_mode) ~= "boolean" then
        error("safe_mode must be a boolean", 2)
    end
    if options.background_interval_ms ~= nil
        and type(options.background_interval_ms) ~= "table"
        and type(options.background_interval_ms) ~= "number" then
        error("background_interval_ms must be a number or table", 2)
    end
    local execute = options.execute
    if options.safe_mode then
        execute = false
    elseif execute == nil and native.available then
        execute = native.run
    end
    local context = {}
    for key, value in pairs(options.context or {}) do context[key] = value end
    context.clock = context.clock or clock
    if not valid_clock(context.clock) then
        error("context clock must provide now_ns and wall_ns", 2)
    end
    local constants
    if type(native.system_constants) == "function" then
        local called, value = pcall(native.system_constants)
        if called then constants = value end
    end
    if type(constants) == "table" then
        context.clock_ticks_per_second = context.clock_ticks_per_second
            or constants.clock_ticks_per_second
        context.page_size_bytes = context.page_size_bytes or constants.page_size_bytes
    end
    if options.safe_mode then
        -- Safe mode is a policy boundary, not a default. Replace even an
        -- injected runner so a reused context cannot retain an executor.
        context.runner = Runner.new({
            execute = false,
            default_timeout_ms = options.helper_timeout_ms or 750,
            default_max_output_bytes = options.helper_max_output_bytes or (1024 * 1024),
        })
    else
        context.runner = context.runner or Runner.new({
            execute = execute,
            default_timeout_ms = options.helper_timeout_ms or 750,
            default_max_output_bytes = options.helper_max_output_bytes or (1024 * 1024),
        })
    end

    local scheduler = Scheduler.new({
        clock = clock,
        context = context,
        max_backoff_ms = options.max_backoff_ms or 30000,
    })
    local collectors = options.collectors or Collectors.new_all(options.collector_options)
    local ordered = {
        "cpu", "memory", "pressure", "disk", "network", "connections", "process", "gpu",
        "cpufreq", "hwmon", "mounts", "cgroup",
    }
    local foreground_floors = {}
    local background_targets = {}
    for _, id in ipairs(ordered) do
        local collector = collectors[id]
        if collector then
            local interval_ms = options.interval_ms or collector.default_interval_ms
            -- Fast dashboard refreshes must not turn full /proc enumeration
            -- into a 4 Hz tax. High-cardinality and hardware collectors keep a
            -- sensible floor while CPU, PSI and I/O remain responsive.
            positive_integer("collector interval for " .. id, interval_ms, Scheduler.MAX_INTERVAL_MS)
            interval_ms = math.max(interval_ms, INTERVAL_FLOORS_MS[id] or 0)
            foreground_floors[id] = INTERVAL_FLOORS_MS[id] or 0
            local background_interval_ms
            if type(options.background_interval_ms) == "table" then
                background_interval_ms = options.background_interval_ms[id]
            elseif type(options.background_interval_ms) == "number" then
                background_interval_ms = options.background_interval_ms
            else
                background_interval_ms = BACKGROUND_INTERVALS_MS[id]
            end
            if background_interval_ms then
                positive_integer("background interval for " .. id,
                    background_interval_ms, Scheduler.MAX_INTERVAL_MS)
                background_targets[id] = background_interval_ms
                background_interval_ms = math.max(interval_ms, background_interval_ms)
            end
            assert(scheduler:add(collector, {
                interval_ms = interval_ms,
                background_interval_ms = background_interval_ms,
            }))
        end
    end

    local history = {}
    for _, key in ipairs(HISTORY_KEYS) do
        history[key] = Ring.new(options.history_capacity or DEFAULT_HISTORY_CAPACITY)
    end
    return setmetatable({
        clock = clock,
        context = context,
        scheduler = scheduler,
        collectors = collectors,
        snapshot = Snapshot.new(0, clock:now_ns()),
        history = history,
        history_window_ns = HISTORY_WINDOW_MS * 1000000,
        interval_ms = options.interval_ms,
        foreground_floors = foreground_floors,
        background_targets = background_targets,
        sequence = 0,
        paused = false,
        capabilities = nil,
    }, Engine)
end

function Engine:probe()
    self.capabilities = self.scheduler:probe_all(self.context)
    return self.capabilities
end

function Engine:set_paused(paused)
    self.paused = paused == true
end

function Engine:set_interval(interval_ms)
    if type(interval_ms) ~= "number" or interval_ms ~= interval_ms
        or interval_ms == math.huge or interval_ms == -math.huge
        or interval_ms % 1 ~= 0 or interval_ms < UpdateFrequency.MIN_INTERVAL_MS
        or interval_ms > UpdateFrequency.MAX_INTERVAL_MS
    then
        return nil, "interval_must_be_100_to_10000_ms"
    end
    self.interval_ms = interval_ms
    for _, id in ipairs(self.scheduler.order) do
        local foreground = math.max(interval_ms, self.foreground_floors[id] or 0)
        local background = self.background_targets[id]
        if background then background = math.max(foreground, background) end
        assert(self.scheduler:set_interval(id, foreground))
        assert(self.scheduler:set_background_interval(id, background))
    end
    return true
end

function Engine:set_active_tab(tab_id, widget_ids)
    if not TAB_COLLECTORS[tab_id] then
        return false, "unknown_tab"
    end
    local visible = widget_visibility(tab_id, widget_ids)
    self.active_tab = tab_id
    self.active_widgets = widget_ids
    self.context.scan_connection_owners = tab_id == "network"
        and (type(widget_ids) ~= "table" or widget_ids.connection_table == true)
    local gpu_scan_was_enabled = self.context.scan_gpu_processes == true
    self.context.scan_gpu_processes = tab_id == "gpu"
        and (type(widget_ids) ~= "table" or widget_ids.gpu_process_table == true)
    for _, id in ipairs(self.scheduler.order) do
        self.scheduler:set_visible(id, visible[id] == true)
    end
    if self.context.scan_gpu_processes and not gpu_scan_was_enabled then
        local gpu_task = self.scheduler:task("gpu")
        if gpu_task then gpu_task.next_due_ns = self.clock:now_ns() end
    end
    return true
end

function Engine:_record_history(snapshot, completed)
    local cpu = snapshot.cpu and snapshot.cpu.total and snapshot.cpu.total.utilization
    local memory
    if snapshot.memory and finite_number(snapshot.memory.total_bytes)
        and snapshot.memory.total_bytes > 0 and finite_number(snapshot.memory.used_bytes) then
        memory = snapshot.memory.used_bytes * 100 / snapshot.memory.total_bytes
    end
    local disks = snapshot.disks and snapshot.disks.devices
    local interfaces = snapshot.network and snapshot.network.interfaces
    local gpu
    for _, device in ipairs(snapshot.gpus and snapshot.gpus.devices or {}) do
        local utilization = device.metrics and device.metrics.utilization_percent
        if finite_number(utilization) then gpu = gpu and math.max(gpu, utilization) or utilization end
    end

    local function record(key, source, value)
        local result = completed[source]
        if not result then return end
        if result.status ~= "ok" then value = nil end
        local timestamp_ns = finite_number(result.timestamp_ns)
            and result.timestamp_ns or snapshot.timestamp_ns
        timestamp_ns = math.min(timestamp_ns, snapshot.timestamp_ns)
        -- A boolean sentinel preserves the ring's dense array shape while the
        -- chart renderer still treats it as a visible sampling gap.
        self.history[key]:push({
            value = finite_number(value) and value or false,
            timestamp_ns = timestamp_ns,
        })
    end
    record("cpu", "cpu", cpu)
    record("memory", "memory", memory)
    record("pressure", "pressure", pressure_value(snapshot.pressure))
    record("disk_read", "disk", sum_devices(disks, "read_bytes_per_second"))
    record("disk_write", "disk", sum_devices(disks, "write_bytes_per_second"))
    record("network_receive", "network", sum_interfaces(interfaces, "rx_bytes_per_second"))
    record("network_transmit", "network", sum_interfaces(interfaces, "tx_bytes_per_second"))
    record("gpu", "gpu", gpu)
    record("cpu_frequency", "cpufreq", average_cpu_frequency(snapshot.cpu_frequency))
    record("temperature", "hwmon", maximum_temperature(snapshot.sensors))
    local workload_summary = snapshot.workloads and snapshot.workloads.summary
    record("workload_cpu", "cgroup", workload_summary and workload_summary.root
        and workload_summary.root.cpu_utilization_percent)
end

function Engine:tick(force)
    if self.paused and not force then
        return self.snapshot, {}
    end
    if force == true then
        for _, id in ipairs(self.scheduler.order) do
            local task = self.scheduler:task(id)
            if task then
                task.next_due_ns = 0
            end
        end
    elseif force == "visible" then
        for _, id in ipairs(self.scheduler.order) do
            local task = self.scheduler:task(id)
            if task and task.visible then task.next_due_ns = 0 end
        end
    end
    local completed = self.scheduler:tick(self.context)
    if next(completed) then
        self.sequence = self.sequence + 1
        self.snapshot = Snapshot.merge(
            self.snapshot,
            completed,
            self.sequence,
            self.clock:now_ns()
        )
        self:_record_history(self.snapshot, completed)
    end
    return self.snapshot, completed
end

function Engine:tick_visible()
    return self:tick("visible")
end

function Engine:next_delay_ms(maximum)
    if maximum ~= nil then
        positive_integer("maximum delay", maximum, Scheduler.MAX_INTERVAL_MS)
    end
    if self.paused then
        -- Pausing intentionally leaves collector deadlines untouched so a
        -- resume can refresh immediately.  Once one deadline has elapsed the
        -- scheduler would otherwise report zero forever and make the terminal
        -- loop busy-poll while no collector is allowed to run.
        return maximum or 1000
    end
    local delay = self.scheduler:next_delay_ms()
    if delay == nil then
        return maximum or 1000
    end
    return math.min(delay, maximum or delay)
end

function Engine:history_values(key)
    local ring = self.history[key]
    if not ring then return {} end
    local entries = ring:values()
    local values = {
        n = #entries,
        timestamps_ns = {},
        window_ns = self.history_window_ns,
        column_ns = HISTORY_COLUMN_MS * 1000000,
        end_ns = self.snapshot.timestamp_ns,
    }
    for index, entry in ipairs(entries) do
        values[index] = entry.value
        values.timestamps_ns[index] = entry.timestamp_ns
    end
    return values
end

function Engine:stop()
    self.scheduler:stop(self.context)
end

Engine.pressure_value = pressure_value
Engine.sum_devices = sum_devices
Engine.sum_interfaces = sum_interfaces
Engine.average_cpu_frequency = average_cpu_frequency
Engine.maximum_temperature = maximum_temperature
Engine.HISTORY_WINDOW_MS = HISTORY_WINDOW_MS
Engine.HISTORY_COLUMN_MS = HISTORY_COLUMN_MS
Engine.DEFAULT_HISTORY_CAPACITY = DEFAULT_HISTORY_CAPACITY

return Engine
