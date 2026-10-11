-- SMBIOS Type 39 power-supply declarations; not live power measurements.
local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local Native = require("wtop.native")
local Platform = require("wtop.platform")
local Source = require("wtop.collectors.smbios_source")

local FirmwarePower = {}
FirmwarePower.__index = FirmwarePower

function FirmwarePower.new(options)
  options = options or {}
  if type(options) ~= "table" then error("FirmwarePower options must be a table", 2) end
  return setmetatable({ id = "firmware_power_supplies", _method_style = true,
    fs = options.fs or FS.default, native = options.native or Native,
    platform = options.platform or Platform.id(),
    base_path = Common.absolute_path("base_path", options.base_path, "/sys/firmware/dmi/tables"),
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 60000),
  }, FirmwarePower)
end

function FirmwarePower:sample(context)
  local started = Common.now_ns(context)
  local input, parsed, reason, read_error = Source.load(self, context)
  if not input then return read_error end
  local source = input.source
  if not parsed then
    return Common.result("error", Common.now_ns(context), nil,
      { reason = reason, source = source })
  end
  if #parsed.firmware_power_supplies == 0 then
    return Common.result("unavailable", Common.now_ns(context), nil,
      { reason = "no_firmware_power_supplies", source = source })
  end
  Source.attach_metadata_issue(parsed, input, self.base_path)
  local result = { supplies = parsed.firmware_power_supplies, issues = parsed.issues,
    partial = parsed.partial, truncated = parsed.truncated,
    major = parsed.major, minor = parsed.minor, docrev = parsed.docrev,
    structure_count = parsed.structure_count, source = source }
  for _, issue in ipairs(result.issues) do
    issue.source = issue.source or (source .. string.format("@0x%x", issue.offset or 0))
  end
  for _, supply in ipairs(result.supplies) do supply.source = source .. "#" .. supply.id end
  local finished = Common.now_ns(context)
  return Common.result("ok", finished, result, { source = source,
    quality = result.partial and "partial" or "fresh",
    reason = result.partial and "firmware_power_supplies_incomplete" or nil,
    duration_ns = Common.elapsed_ns(finished, started) or 0 })
end

function FirmwarePower:probe(context)
  local result = self:sample(context)
  if result.status == "ok" then return Capability.available({ source = result.source }) end
  if result.status == "denied" then return Capability.denied(result.reason, { source = result.source }) end
  return Capability.unavailable(result.reason, { source = result.source })
end

return FirmwarePower
