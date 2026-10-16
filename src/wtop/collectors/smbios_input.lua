-- One bounded raw input, shared by the firmware views in the parent. Keep the
-- existing batch parser there instead of transporting eleven full parse trees.
local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local Source = require("wtop.collectors.smbios_source")
local Input = {}
Input.__index = Input

function Input.new(options)
    options = options or {}
    if type(options) ~= "table" then error("SMBIOS input options must be a table", 2) end
    return setmetatable({ id = "smbios_input", _method_style = true,
        default_interval_ms = 60000, platform = "linux", fs = options.fs or FS.default,
        base_path = Common.absolute_path("base_path", options.base_path, "/sys/firmware/dmi/tables") }, Input)
end

function Input:probe()
    return Capability.available({ source = self.base_path .. "/DMI" })
end

function Input:sample(context)
    local started = Common.now_ns(context)
    local input, failure = Source.read(self, context)
    if not input then return failure end
    local finished = Common.now_ns(context)
    return Common.result("ok", finished, input, { source = input.source,
        duration_ns = Common.elapsed_ns(finished, started) or 0 })
end

return Input
