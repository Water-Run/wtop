-- One bounded, nonblocking reader while the RAM detail is open. No helper exec.
local Collector = require("wtop.collectors.ram_bandwidth")
local Worker = require("wtop.collectors.hardware_worker")
local Model = require("wtop.inspectors.model")
local Ring = require("wtop.model.ring")
local Json = require("wtop.format.json")
local Native = require("wtop.native")
local M = {}
M.__index = M

local function number(value)
    return type(value) == "number" and value == value and value >= 0 and value < math.huge
end

function M.available(native)
    native = native or Native
    return Worker.available(native) and type(native.hardware_worker_sources) == "table"
        and native.hardware_worker_sources.ram_bandwidth == true
end

function M.new(entity, options)
    options = options or {}
    assert(type(entity) == "table", "memory entity required")
    if entity.measurement_scope == "controller_pmu" then
        assert(require("wtop.inspectors.ram_bandwidth").matches_pmu(entity.id), "invalid memory PMU")
    end
    local configuration = entity.measurement_scope == "controller_pmu"
        and { pmu = entity.id, type = entity.type } or {}
    local factory = options.create_worker or function()
        return Worker.new(Collector.new(configuration), configuration, options.native or Native)
    end
    local worker = options.worker or factory()
    return setmetatable({ worker = worker, history = Ring.new(128), interval_ns = 1000000000,
        create_worker = factory, next_due_ns = 0, epoch = 0, accepted = 0 }, M)
end

function M:record(result, now)
    local timestamp = result.timestamp_ns
    if not number(timestamp) or timestamp > now or self.last_timestamp and timestamp <= self.last_timestamp then return false end
    local entity = result.entity
    if entity and entity.evidence then
        local encoded, signature = pcall(Json.encode, { scope = entity.evidence.measurement_scope,
            pmus = entity.evidence.pmus }, { max_bytes = 262144 })
        if not encoded then
            self.history:clear();self.signature = nil
            self.last_timestamp, self.current_result = timestamp, result
            return true
        end
        if signature ~= self.signature then
            self.history:clear();self.epoch = self.epoch + 1;self.signature = signature
        end
    end
    local metrics = entity and entity.metrics or {}
    local function value(name)
        local field = metrics[name]
        if result.status == "ok" and field and (field.quality == "fresh" or field.quality == "estimated")
            and number(field.value) then return field.value end
        return false
    end
    self.last_timestamp, self.current_result = timestamp, result
    self.history:push({ timestamp_ns = timestamp, read = value("read_bandwidth"), write = value("write_bandwidth") })
    self.accepted = self.accepted + 1
    return true
end

function M:poll(context, now)
    if self.closed or self.paused_at or not number(now) or now < self.next_due_ns then return false end
    self.worker = self.worker or self.create_worker()
    if context.safe_mode then
        if self.worker then self.worker:close();self.worker = nil end
        local result = Model.result("unavailable", nil, {}, { timestamp_ns = now, reason = "safe_mode" })
        self.next_due_ns = now + 5000000000
        return self:record(result, now)
    end
    self.started_ns = self.started_ns or now
    local result = self.worker:sample(context)
    if result.sampling_pending then
        self.next_due_ns = now + 25000000
        return false
    end
    self.next_due_ns = math.max(now, self.started_ns + self.interval_ns)
    self.started_ns = nil
    local inspection = result.data and result.data.inspection
    if type(inspection) ~= "table" then
        inspection = Model.result("error", nil, {}, { timestamp_ns = now,
            reason = result.reason or "hardware_invalid_response" })
    end
    if inspection.status ~= "ok" then self.next_due_ns = now + 5000000000 end
    return self:record(inspection, now)
end

function M:series(direction, now)
    assert(direction == "read" or direction == "write", "bandwidth direction")
    local values = { timestamps_ns = {}, window_ns = 60000000000, end_ns = now, column_ns = 1000000000 }
    local peak = 0
    for _, point in self.history:iter() do
        values[#values+1], values.timestamps_ns[#values.timestamps_ns+1] = point[direction], point.timestamp_ns
        if point.timestamp_ns >= now - values.window_ns and number(point[direction]) then peak = math.max(peak, point[direction]) end
    end
    return values, peak
end

function M:current(now)
    local result = self.current_result
    if not result or result.status == "ok" and now - result.timestamp_ns > 3000000000 then
        return Model.result("unavailable", nil, {}, { timestamp_ns = result and result.timestamp_ns or now,
            quality = result and "stale" or "unavailable", reason = "hardware_query_pending", provider = "perf_event_open" })
    end
    return result
end

function M:close()
    if self.closed then return end
    self.closed = true
    if self.worker then self.worker:close();self.worker = nil end
    self.current_result = nil;self.history:clear()
end

function M:set_paused(paused, now)
    if self.closed then return end
    if paused and not self.paused_at then
        self.paused_at = now
        if self.worker then self.worker:close();self.worker = nil end
        self.started_ns = nil
    elseif not paused and self.paused_at then
        self.paused_at, self.next_due_ns = nil, now
    end
end

return M
