-- Static SMBIOS board/enclosure declarations, not live chassis health.
local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local Native = require("wtop.native")
local Platform = require("wtop.platform")
local Source = require("wtop.collectors.smbios_source")
local FirmwareEnclosures = {}
FirmwareEnclosures.__index = FirmwareEnclosures

function FirmwareEnclosures.new(options)
    options = options or {}
    if type(options) ~= "table" then error("enclosure options must be a table", 2) end
    return setmetatable({ id = "firmware_enclosures", _method_style = true,
        fs = options.fs or FS.default, native = options.native or Native,
        platform = options.platform or Platform.id(),
        base_path = Common.absolute_path("base_path", options.base_path, "/sys/firmware/dmi/tables"),
        default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 60000) }, FirmwareEnclosures)
end

function FirmwareEnclosures:sample(context)
    local started = Common.now_ns(context)
    local input, parsed, reason, failure = Source.load(self, context)
    if not input then return failure end
    if not parsed then
        return Common.result("error", Common.now_ns(context), nil, { reason = reason, source = input.source })
    end
    if #parsed.baseboards == 0 and #parsed.enclosures == 0 then
        return Common.result("unavailable", Common.now_ns(context), nil,
            { reason = "no_firmware_enclosures", source = input.source })
    end
    Source.attach_metadata_issue(parsed, input, self.base_path)
    for _, issue in ipairs(parsed.issues) do
        issue.source = issue.source or (input.source .. string.format("@0x%x", issue.offset or 0))
    end
    for _, list in ipairs({ parsed.baseboards, parsed.enclosures }) do
        for _, record in ipairs(list) do record.source = input.source .. "#" .. record.id end
    end
    local finished = Common.now_ns(context)
    return Common.result("ok", finished, { baseboards = parsed.baseboards, enclosures = parsed.enclosures,
        partial = parsed.partial, truncated = parsed.truncated, issues = parsed.issues, source = input.source,
        major = parsed.major, minor = parsed.minor, docrev = parsed.docrev, structure_count = parsed.structure_count },
        { source = input.source, quality = parsed.partial and "partial" or "fresh",
          reason = parsed.partial and "firmware_enclosures_incomplete" or nil,
          duration_ns = Common.elapsed_ns(finished, started) or 0 })
end

function FirmwareEnclosures:probe(context)
    local result = self:sample(context)
    if result.status == "ok" then return Capability.available({ source = result.source }) end
    if result.status == "denied" then return Capability.denied(result.reason, { source = result.source }) end
    return Capability.unavailable(result.reason, { source = result.source })
end

return FirmwareEnclosures
