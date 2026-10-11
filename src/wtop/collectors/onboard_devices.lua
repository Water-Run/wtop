-- SMBIOS Type 10/41 firmware declarations, independent of PCI enumeration.
local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local Native = require("wtop.native")
local Platform = require("wtop.platform")
local Source = require("wtop.collectors.smbios_source")

local OnboardDevices = {}
OnboardDevices.__index = OnboardDevices

function OnboardDevices.new(options)
  options = options or {}
  if type(options) ~= "table" then error("OnboardDevices options must be a table", 2) end
  return setmetatable({ id = "onboard_devices", _method_style = true,
    fs = options.fs or FS.default, native = options.native or Native,
    platform = options.platform or Platform.id(),
    base_path = Common.absolute_path("base_path", options.base_path, "/sys/firmware/dmi/tables"),
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 60000),
  }, OnboardDevices)
end

function OnboardDevices:sample(context)
  local started = Common.now_ns(context)
  local input, parsed, reason, read_error = Source.load(self, context)
  if not input then return read_error end
  local source = input.source
  if not parsed then
    return Common.result("error", Common.now_ns(context), nil,
      { reason = reason, source = source })
  end
  if #parsed.onboard_devices == 0 then
    return Common.result("unavailable", Common.now_ns(context), nil,
      { reason = "no_onboard_devices", source = source })
  end
  Source.attach_metadata_issue(parsed, input, self.base_path)
  local result = { devices = parsed.onboard_devices, issues = parsed.issues,
    partial = parsed.partial, truncated = parsed.truncated,
    major = parsed.major, minor = parsed.minor, docrev = parsed.docrev,
    structure_count = parsed.structure_count, source = source }
  for _, issue in ipairs(result.issues) do
    issue.source = issue.source or (source .. string.format("@0x%x", issue.offset or 0))
  end
  for _, device in ipairs(result.devices) do device.source = source .. "#" .. device.id end
  local finished = Common.now_ns(context)
  return Common.result("ok", finished, result, { source = source,
    quality = result.partial and "partial" or "fresh",
    reason = result.partial and "onboard_devices_incomplete" or nil,
    duration_ns = Common.elapsed_ns(finished, started) or 0 })
end

function OnboardDevices:probe(context)
  local result = self:sample(context)
  if result.status == "ok" then return Capability.available({ source = result.source }) end
  if result.status == "denied" then return Capability.denied(result.reason, { source = result.source }) end
  return Capability.unavailable(result.reason, { source = result.source })
end

return OnboardDevices
