-- SMBIOS probe specifications and cooling declarations, not live sensors.
local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local Native = require("wtop.native")
local Platform = require("wtop.platform")
local Source = require("wtop.collectors.smbios_source")
local Probes = {}
Probes.__index = Probes

function Probes.new(options)
  options = options or {}
  if type(options) ~= "table" then error("firmware probe options must be a table", 2) end
  return setmetatable({ id = "firmware_probes", _method_style = true,
    fs = options.fs or FS.default, native = options.native or Native,
    platform = options.platform or Platform.id(),
    base_path = Common.absolute_path("base_path", options.base_path, "/sys/firmware/dmi/tables"),
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 60000) }, Probes)
end

function Probes:sample(context)
  local started = Common.now_ns(context)
  local input, parsed, reason, failure, cohort = Source.load(self, context)
  if not input then return failure end
  if not parsed then return Common.result("error", Common.now_ns(context), nil,
    { reason = reason, source = input.source }) end
  if #parsed.firmware_probes == 0 and #parsed.firmware_cooling == 0 then
    return Common.result("unavailable", Common.now_ns(context), nil,
      { reason = "no_firmware_probes", source = input.source })
  end
  Source.attach_metadata_issue(parsed, input, self.base_path)
  for _, issue in ipairs(parsed.issues) do
    issue.source = issue.source or (input.source .. string.format("@0x%x", issue.offset or 0))
  end
  for _, list in ipairs({ parsed.firmware_probes, parsed.firmware_cooling }) do
    for _, record in ipairs(list) do record.source = input.source .. "#" .. record.id end
  end
  local finished = Common.now_ns(context)
  return Common.result("ok", finished, { probes = parsed.firmware_probes,
    cooling_devices = parsed.firmware_cooling, issues = parsed.issues,
    partial = parsed.partial, truncated = parsed.truncated,
    major = parsed.major, minor = parsed.minor, docrev = parsed.docrev,
    structure_count = parsed.structure_count, source = input.source, _smbios_cohort = cohort,
    _handles_complete = parsed._handles_complete },
    { source = input.source, quality = parsed.partial and "partial" or "fresh",
      reason = parsed.partial and "firmware_probes_incomplete" or nil,
      duration_ns = Common.elapsed_ns(finished, started) or 0 })
end

function Probes:probe(context)
  local result = self:sample(context)
  if result.status == "ok" then return Capability.available({ source = result.source }) end
  if result.status == "denied" then return Capability.denied(result.reason, { source = result.source }) end
  return Capability.unavailable(result.reason, { source = result.source })
end

return Probes
