local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local Hardware = require("wtop.collectors.hardware_worker")
local Input = require("wtop.collectors.smbios_input")
local M, Shared, Proxy = {}, {}, {}
Shared.__index, Proxy.__index = Shared, Proxy
M.sources = { memory_devices = true, expansion_slots = true, port_connectors = true,
    onboard_devices = true, firmware_batteries = true, firmware_power_supplies = true,
    firmware_enclosures = true,
    platform_firmware = true,
    firmware_bmcs = true, firmware_tpms = true, firmware_components = true,
    host_interfaces = true, processor_firmware = true }

function M.new(options)
    options = options or {}
    return setmetatable({ reader = options.reader
        or Hardware.new(Input.new(options.input), options.input) }, Shared)
end

local function closed_result(context)
    return Common.result("error", Common.now_ns(context), nil,
        { quality = "stale", reason = "hardware_worker_closed" })
end

function Shared:read(_, context)
    if self.closed then return nil, closed_result(context) end
    local batch = assert(context._collector_batch, "SMBIOS worker requires a batch")
    local cache = batch.smbios_inputs
    if not cache then cache = {}; batch.smbios_inputs = cache end
    local result = cache[self]
    if not result then result = self.reader:sample(context); cache[self] = result end
    if result.status ~= "ok" then return nil, result end
    return result.data
end

function Shared:close()
    if self.closed then return end
    self.closed = true
    self.reader:close()
end

function Shared:wrap(collector)
    assert(M.sources[collector.id], "unsupported SMBIOS view")
    return setmetatable({ id = collector.id, _method_style = true, collector = collector,
        shared = self, default_interval_ms = collector.default_interval_ms }, Proxy)
end

local function capability(result)
    if result.status == "ok" then return Capability.available({ source = result.source }) end
    if result.status == "denied" then return Capability.denied(result.reason, { source = result.source }) end
    return Capability.unavailable(result.reason, { source = result.source })
end

function Proxy:_sample(context)
    if self.closed then
        local result = closed_result(context); result.capability = capability(result); return result
    end
    local ctx = {}
    for key, value in pairs(context or {}) do ctx[key] = value end
    ctx._collector_batch = ctx._collector_batch or {}
    ctx.smbios_input = self.shared
    local raw = self.collector:sample(ctx)
    -- Failures from the raw reader are shared by the firmware consumers.
    -- Each result owns its status/capability fields, just as parsed records do.
    local result = {}
    for key, value in pairs(raw) do result[key] = value end
    local sample = ctx._collector_batch.smbios_inputs
        and ctx._collector_batch.smbios_inputs[self.shared]
    if result.status == "ok" and sample and sample.status == "ok" then
        result.value_timestamp_ns = sample.value_timestamp_ns or sample.timestamp_ns
        result.transport = sample.transport
        result.sample_started_ns = sample.sample_started_ns
        result.sample_finished_ns = sample.sample_finished_ns
    end
    result.capability = capability(result)
    return result
end

function Proxy:probe(context)
    local result = self:_sample(context)
    if not result.sampling_pending then
        self.ready = result
        self.ready_safe_mode = context and context.safe_mode == true or false
    end
    return result.capability
end

function Proxy:sample(context)
    local safe_mode = context and context.safe_mode == true or false
    if not self.closed and self.ready and self.ready_safe_mode == safe_mode then
        local result = self.ready; self.ready = nil; return result
    end
    self.ready = nil
    return self:_sample(context)
end

function Proxy:close(context)
    self.closed, self.ready = true, nil
    if type(self.collector.close) == "function" then self.collector:close(context) end
end

return M
