-- Runs in the exec'd hardware reader, using its own clock and collector state.
local Wire = require("wtop.core.worker_wire")
local Native = require("wtop.native")

return function(id, configuration)
    local options = Wire.decode(configuration)
    assert(type(options) == "table", "hardware_configuration")
    local collector = require("wtop.collectors." .. id).new(options)
    local previous
    return function(safe_mode)
        local context = { safe_mode = safe_mode, native = Native,
            clock = { now_ns = Native.monotonic_ns, wall_ns = Native.realtime_ns } }
        local capability = collector:probe(context)
        local result = collector:sample(context, previous)
        previous = result
        return Wire.encode({ capability = capability, result = result })
    end
end
