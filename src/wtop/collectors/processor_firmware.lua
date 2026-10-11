local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local Native = require("wtop.native")
local Platform = require("wtop.platform")
local Source = require("wtop.collectors.smbios_source")

local ProcessorFirmware = {}
ProcessorFirmware.__index = ProcessorFirmware

function ProcessorFirmware.new(options)
  options = options or {}
  if type(options) ~= "table" then error("ProcessorFirmware options must be a table", 2) end
  return setmetatable({ id = "processor_firmware", _method_style = true,
    fs = options.fs or FS.default, native = options.native or Native,
    platform = options.platform or Platform.id(),
    base_path = Common.absolute_path("base_path", options.base_path, "/sys/firmware/dmi/tables"),
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 60000),
  }, ProcessorFirmware)
end

function ProcessorFirmware:sample(context)
  local started = Common.now_ns(context)
  local input, parsed, reason, read_error = Source.load(self, context)
  if not input then return read_error end
  if not parsed then
    return Common.result("error", Common.now_ns(context), nil,
      { reason = reason, source = input.source })
  end
  if #parsed.processors == 0 and #parsed.caches == 0 then
    return Common.result("unavailable", Common.now_ns(context), nil,
      { reason = "no_processor_firmware", source = input.source })
  end
  Source.attach_metadata_issue(parsed, input, self.base_path)
  local result = { processors = parsed.processors, caches = parsed.caches,
    issues = parsed.issues, partial = parsed.partial, truncated = parsed.truncated,
    major = parsed.major, minor = parsed.minor, docrev = parsed.docrev,
    structure_count = parsed.structure_count, source = input.source }
  for _, issue in ipairs(result.issues) do
    issue.source = issue.source or (input.source .. string.format("@0x%x", issue.offset or 0))
  end
  for _, list in ipairs({ result.processors, result.caches }) do
    for _, record in ipairs(list) do record.source = input.source .. "#" .. record.id end
  end
  local finished = Common.now_ns(context)
  return Common.result("ok", finished, result, { source = input.source,
    quality = result.partial and "partial" or "fresh",
    reason = result.partial and "processor_firmware_incomplete" or nil,
    duration_ns = Common.elapsed_ns(finished, started) or 0 })
end

function ProcessorFirmware:probe(context)
  local result = self:sample(context)
  if result.status == "ok" then return Capability.available({ source = result.source }) end
  if result.status == "denied" then return Capability.denied(result.reason, { source = result.source }) end
  return Capability.unavailable(result.reason, { source = result.source })
end

return ProcessorFirmware
