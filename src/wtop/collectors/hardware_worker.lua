local Common = require("wtop.collectors.common")
local Wire = require("wtop.core.worker_wire")
local Native = require("wtop.native")

local M = {}
local Proxy = {}
Proxy.__index = Proxy
M.sources = { hwmon = true, cpufreq = true, powercap = true, cpu_limits = true,
    thermal_throttle = true, cpuidle = true, thermal_zones = true, smbios_input = true, gpu_drm = true,
    cpu_clocks = true, cpuid = true, spd = true }

function M.available(native)
    native = native or Native
    return native.available and type(native.hardware_worker_open) == "function"
        and type(native.hardware_worker_query) == "function"
        and type(native.hardware_worker_close) == "function"
end

function M.new(collector, options, native)
    native = native or Native
    assert(M.sources[collector.id] or (type(native.hardware_worker_sources) == "table"
        and native.hardware_worker_sources[collector.id]), "unsupported hardware worker")
    local configuration = Wire.encode(options or {})
    assert(#configuration <= 65536, "hardware_configuration_size")
    return setmetatable({ id = collector.id, _method_style = true,
        default_interval_ms = collector.default_interval_ms, configuration = configuration,
        native = native }, Proxy)
end

function Proxy:_read(context)
    local Native = self.native
    if self.closed then return nil, "hardware_worker_closed" end
    local safe_mode = context and context.safe_mode == true or false
    if self.session and self.safe_mode ~= safe_mode then
        Native.hardware_worker_close(self.session, 0)
        self.session, self.ready = nil, nil
    end
    self.safe_mode = safe_mode
    if not self.session then
        local ok, session = pcall(Native.hardware_worker_open, self.id, self.configuration)
        if not ok or not session then return nil, "hardware_worker_unavailable" end
        self.session = session
    end
    local scan = not context or context.scan_gpu_processes ~= false
    self.scan = scan
    local ok, bytes, metadata = pcall(Native.hardware_worker_query, self.session, safe_mode, 0, scan)
    if not ok then return nil, "hardware_allocation_failed" end
    if not bytes then
        if metadata == "hardware_query_pending" then
            self.pending_since_ns = self.pending_since_ns or Common.now_ns(context)
        else self.pending_since_ns = nil end
        return nil, metadata
    end
    self.pending_since_ns = nil
    local decoded, response = pcall(Wire.decode, bytes)
    if not decoded or type(response) ~= "table" or type(response.result) ~= "table"
        or type(response.capability) ~= "table" or type(metadata) ~= "table" then
        return nil, "hardware_invalid_response"
    end
    local result, now = response.result, Common.now_ns(context)
    local observed = result.timestamp_ns
    if type(observed) ~= "number" or observed < metadata.sample_started_ns
        or observed > metadata.sample_finished_ns or observed > now then
        return nil, "hardware_invalid_response"
    end
    -- Attempt/receive time and measurement time remain distinct. Re-polling a
    -- pending or failed reader never assigns a new timestamp to an old value.
    result.value_timestamp_ns = observed
    result.timestamp_ns = now
    result.capability = response.capability
    result.transport = "process"
    result.sample_started_ns = metadata.sample_started_ns
    result.sample_finished_ns = metadata.sample_finished_ns
    -- SPD has no counter baseline and is normally sampled once a minute.
    -- Release its VM after a complete reply while keeping the public result.
    if self.id == "spd" then
        local session = self.session
        self.session = nil
        Native.hardware_worker_close(session, 0)
    end
    return result
end

function Proxy:probe(context)
    local result, reason = self:_read(context)
    if result then self.ready = result; return result.capability end
    local pending = reason == "hardware_query_pending"
    return { state = pending and "unavailable" or "error",
        available = false, reason = reason }
end

function Proxy:sample(context)
    local result, reason
    local safe_mode = context and context.safe_mode == true or false
    local scan = not context or context.scan_gpu_processes ~= false
    if self.ready and self.safe_mode == safe_mode and not self.closed
        and ((self.id ~= "gpu_drm" and self.id ~= "gpu") or self.scan == scan) then
        result, self.ready = self.ready, nil
    else self.ready = nil; result, reason = self:_read(context) end
    if result then return result end
    local pending = reason == "hardware_query_pending"
    local now = Common.now_ns(context)
    return { status = "error", quality = "stale", reason = reason,
        timestamp_ns = now, retry_after_ms = pending and 25 or 5000,
        sampling_pending = pending,
        -- Normal round trips don't publish a gap or redraw the table. A read
        -- still pending after 100 ms publishes its retained value as stale.
        defer_publish = pending and self.pending_since_ns ~= nil
            and now >= self.pending_since_ns and now - self.pending_since_ns < 100000000,
        capability = { state = pending and "unavailable" or "error", available = false, reason = reason } }
end

function Proxy:close()
    self.closed, self.ready = true, nil
    if self.session then self.native.hardware_worker_close(self.session, 0); self.session = nil end
end

return M
